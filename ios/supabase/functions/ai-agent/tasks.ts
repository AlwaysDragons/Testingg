// Task modes: one-shot jobs the app asks for (daily briefing, ...). Each has its own instructions,
// a narrower tool list and a schema-validated finish tool that returns a structured result.
// Task runs are not saved to the chat history.
import { z } from "npm:zod@4.6.7";
import type { FinishTool } from "./agent.ts";
import { TOOL_DEFINITIONS, type ToolName } from "./tools.ts";

export const READ_ONLY_TOOLS: ToolName[] = ["query_area", "get_dashboard_summary", "get_daily_briefing", "list_reminders"];

export type Task = {
  /** Appended to the base system prompt. */
  instructions: string;
  /** The user turn, built from the request's params. */
  prompt: (params: Record<string, unknown>) => string;
  tools: ToolName[];
  finish: FinishTool;
  effort?: "low" | "medium" | "high";
};

function finishTool<S extends z.ZodType>(name: string, description: string, schema: S): FinishTool {
  const { $schema: _ignored, ...input_schema } = z.toJSONSchema(schema, { io: "input" }) as Record<string, unknown>;
  return {
    definition: { name, description, input_schema: { type: "object", ...input_schema } },
    validate: (input) => {
      const r = schema.safeParse(input);
      return r.success ? { ok: true, value: r.data } : { ok: false, error: `invalid_arguments: ${z.prettifyError(r.error)}` };
    },
  };
}

export const TASKS: Record<string, Task> = {
  briefing: {
    instructions: `Task: write the user's daily briefing. Call get_daily_briefing (and get_dashboard_summary if useful), then call submit_briefing.
- line: one calm sentence of at most 20 words: the single most useful thing about today (what's due, what's behind, or a streak). No greeting.
- detail: up to 3 short lines, each starting with "- ", only facts from the tools (due items, overdue, reminders, yesterday's wins). Omit if nothing to add.
- Use only numbers that appear in tool results.`,
    prompt: (p) => `Write today's briefing.${typeof p.device_context === "string" ? `\nFrom the device: ${p.device_context}` : ""}`,
    tools: READ_ONLY_TOOLS,
    finish: finishTool("submit_briefing", "Return the finished briefing.", z.strictObject({
      line: z.string().trim().min(1).max(200),
      detail: z.string().trim().max(1200).optional(),
    })),
    effort: "low",
  },
};

export function toolsFor(task: Task) {
  return TOOL_DEFINITIONS.filter((t) => (task.tools as string[]).includes(t.name));
}
