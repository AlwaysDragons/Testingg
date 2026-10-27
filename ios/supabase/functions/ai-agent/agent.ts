// The tool-calling loop. Runtime-agnostic: the Claude client and the tool runner are passed in,
// so tests can run it with fakes.
import type Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { type DeviceAction, TOOL_DEFINITIONS, type ToolOutcome } from "./tools.ts";

type MessageParam = Anthropic.Beta.Messages.BetaMessageParam;
type ToolResult = Anthropic.Beta.Messages.BetaToolResultBlockParam;

export const DEFAULT_MODEL = "claude-sonnet-5-5";
const MAX_STEPS = 8; // tool-calling rounds per message

// Stable across requests so it stays in the prompt cache. Per-request facts (time, timezone)
// go in the user turn instead.
export const SYSTEM_PROMPT = `You run the user's personal life dashboard. Everything is organised into areas (gym, tasks, goals, habits, finance, custom) holding items, logs and metrics. You read and change it only through your tools.

Rules:
- Check the data with a tool before answering questions about it; never answer from memory.
- Never invent numbers. Record only values the user stated; use null or omit what is unknown.
- Reuse ids from earlier tool results so items are updated, not duplicated.
- Ask one short question when a request is ambiguous. If the user says "remind me" without a time, ask for the time.
- If something fits no existing area, propose creating one and wait for a yes.
- Omit notify_mode unless the user specified one; their default applies.
- Reminders are added to Apple Reminders by the app after you create them.
- Habits are items with a recurrence; mark them done with log_habit. Goals are items whose milestones are child items (parent_id); goal progress rolls up automatically.
- Reply in plain language, at most 2 sentences unless the user asks for detail. After changes, confirm what was done in one short line. No emoji, no exclamation marks.`;

export type ToolCallLog = { name: string; input: unknown; ok: boolean; error?: string };
export type AgentResult = {
  reply: string;
  toolCalls: ToolCallLog[];
  deviceActions: DeviceAction[];
  stopReason: string | null;
  /** Task modes: the validated input of the finish tool. */
  result?: unknown;
  /** Every successful tool result, in order (task modes use these, e.g. capture undo). */
  toolResults?: { name: string; result: unknown }[];
};

/** A schema-validated "finish" tool that ends a task mode with a structured result. */
export type FinishTool = {
  definition: { name: string; description: string; input_schema: { type: "object"; [key: string]: unknown } };
  validate: (input: unknown) => { ok: true; value: unknown } | { ok: false; error: string };
};

export type AgentDeps = {
  createMessage: (params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming) => Promise<Anthropic.Beta.Messages.BetaMessage>;
  runTool: (name: string, input: unknown) => Promise<ToolOutcome>;
  model?: string;
  effort?: "low" | "medium" | "high" | "xhigh" | "max";
  /** Task modes: a different system prompt, a narrower tool list, and a finish tool. */
  system?: string;
  tools?: typeof TOOL_DEFINITIONS;
  finish?: FinishTool;
};

export async function runAgent(history: MessageParam[], userTurn: MessageParam, deps: AgentDeps): Promise<AgentResult> {
  // Append-only within the turn: assistant content (thinking blocks included) is passed back unchanged.
  const messages: MessageParam[] = [...history, userTurn];
  const toolCalls: ToolCallLog[] = [];
  const deviceActions: DeviceAction[] = [];
  const toolResults: { name: string; result: unknown }[] = [];
  const tools = [...(deps.tools ?? TOOL_DEFINITIONS), ...(deps.finish ? [deps.finish.definition] : [])];

  for (let step = 0; step < MAX_STEPS; step++) {
    const response = await deps.createMessage({
      model: deps.model ?? DEFAULT_MODEL,
      max_tokens: 16000,
      system: deps.system ?? SYSTEM_PROMPT,
      tools,
      messages,
      thinking: { type: "adaptive" },
      output_config: { effort: deps.effort ?? "medium" },
      cache_control: { type: "ephemeral" },
      // Retry policy declines on a fallback model instead of failing the turn.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
    });

    if (response.stop_reason === "refusal") {
      return { reply: "I can't help with that one.", toolCalls, deviceActions, stopReason: "refusal" };
    }

    const toolUses = response.content.filter((b): b is Anthropic.Beta.Messages.BetaToolUseBlock => b.type === "tool_use");
    if (response.stop_reason !== "tool_use" || toolUses.length === 0) {
      return { reply: textOf(response.content), toolCalls, deviceActions, stopReason: response.stop_reason, toolResults };
    }

    messages.push({ role: "assistant", content: response.content });

    // Run this round's calls in order (later calls may depend on earlier writes), then return
    // every result in one user message.
    const results: ToolResult[] = [];
    for (const use of toolUses) {
      if (deps.finish && use.name === deps.finish.definition.name) {
        const v = deps.finish.validate(use.input);
        if (v.ok) {
          toolCalls.push({ name: use.name, input: use.input, ok: true });
          return { reply: textOf(response.content), toolCalls, deviceActions, stopReason: "finished", result: v.value, toolResults };
        }
        toolCalls.push({ name: use.name, input: use.input, ok: false, error: v.error });
        results.push({ type: "tool_result", tool_use_id: use.id, content: JSON.stringify({ error: v.error }), is_error: true });
        continue;
      }
      const outcome = await deps.runTool(use.name, use.input);
      if (outcome.ok) toolResults.push({ name: use.name, result: outcome.result });
      toolCalls.push({ name: use.name, input: use.input, ok: outcome.ok, ...(outcome.ok ? {} : { error: outcome.error }) });
      if (outcome.ok && outcome.deviceAction) deviceActions.push(outcome.deviceAction);
      results.push({
        type: "tool_result",
        tool_use_id: use.id,
        content: JSON.stringify(outcome.ok ? outcome.result : { error: outcome.error }),
        ...(outcome.ok ? {} : { is_error: true }),
      });
    }
    messages.push({ role: "user", content: results });
  }

  return { reply: "That took too many steps. Try a smaller request.", toolCalls, deviceActions, stopReason: "max_steps", toolResults };
}

function textOf(content: Anthropic.Beta.Messages.BetaContentBlock[]): string {
  return content
    .filter((b): b is Anthropic.Beta.Messages.BetaTextBlock => b.type === "text")
    .map((b) => b.text)
    .join("\n")
    .trim();
}

// Rebuild prior turns from stored ai_messages (text only, oldest first). Consecutive
// same-role rows (e.g. a turn that failed) are merged so roles alternate.
export function historyFrom(rows: { role: string; content: string | null }[]): MessageParam[] {
  const out: MessageParam[] = [];
  for (const row of rows) {
    if ((row.role !== "user" && row.role !== "assistant") || !row.content) continue;
    const last = out[out.length - 1];
    if (last && last.role === row.role) {
      last.content = `${last.content}\n\n${row.content}`;
    } else {
      out.push({ role: row.role, content: row.content });
    }
  }
  while (out.length && out[0].role !== "user") out.shift();
  return out;
}
