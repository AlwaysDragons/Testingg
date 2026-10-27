// ai-agent Edge Function.
// POST { "message": "..." } with the user's Supabase session token as `Authorization: Bearer <jwt>`.
// Returns { reply, device_actions, tool_calls }.
// Task modes: POST { "mode": "briefing", "params": {...} } returns { result, reply, device_actions, tool_calls }
// (see tasks.ts); task runs are not saved to the chat history.
//
// Secrets: ANTHROPIC_API_KEY (set with `supabase secrets set`). SUPABASE_URL and SUPABASE_ANON_KEY
// are injected by Supabase. The service_role key is NOT used: every query runs as the user, so RLS applies.
// Optional: AI_MODEL (default claude-sonnet-5-5), AI_EFFORT (default medium).
import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
import { type AgentDeps, DEFAULT_MODEL, historyFrom, runAgent, SYSTEM_PROMPT } from "./agent.ts";
import { TASKS, toolsFor } from "./tasks.ts";
import { runTool } from "./tools.ts";

const MAX_MESSAGE_CHARS = 4000;
const HISTORY_LIMIT = 20;
const EFFORTS = ["low", "medium", "high", "xhigh", "max"] as const;

const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
const effortEnv = Deno.env.get("AI_EFFORT") as AgentDeps["effort"];
const effort = effortEnv && EFFORTS.includes(effortEnv) ? effortEnv : "medium";
const model = Deno.env.get("AI_MODEL") || DEFAULT_MODEL;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const auth = req.headers.get("Authorization");
  if (!auth?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  // A client acting as this user: RLS limits every read and write to their rows.
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await db.auth.getUser(auth.slice(7));
  if (userError || !userData.user) return json({ error: "unauthorized" }, 401);

  let message: string;
  let mode = "chat";
  let params: Record<string, unknown> = {};
  try {
    const body = await req.json();
    message = typeof body?.message === "string" ? body.message.trim() : "";
    if (typeof body?.mode === "string") mode = body.mode;
    if (body?.params && typeof body.params === "object") params = body.params;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  if (JSON.stringify(params).length > MAX_MESSAGE_CHARS * 2) return json({ error: "params_too_long" }, 400);
  if (mode !== "chat") return runTask(mode, params, db);
  if (!message) return json({ error: "message_required" }, 400);
  if (message.length > MAX_MESSAGE_CHARS) return json({ error: "message_too_long" }, 400);

  // Prior turns (newest N, then oldest first) and the user's settings.
  const [{ data: rows }, { data: settings }] = await Promise.all([
    db.from("ai_messages").select("role, content").in("role", ["user", "assistant"])
      .order("created_at", { ascending: false }).limit(HISTORY_LIMIT),
    db.from("user_settings").select("timezone, default_notify_mode").maybeSingle(),
  ]);
  const history = historyFrom((rows ?? []).reverse());

  const { error: saveError } = await db.from("ai_messages").insert({ role: "user", content: message });
  if (saveError) return json({ error: "save_failed" }, 500);

  // Per-request facts go in the user turn (not the system prompt) so the cached prefix stays stable.
  const timezone = settings?.timezone ?? "UTC";
  const context = `Now: ${new Date().toISOString()} (user timezone ${timezone}; default notify mode ${settings?.default_notify_mode ?? "app"}).`;

  try {
    const result = await runAgent(history, {
      role: "user",
      content: [{ type: "text", text: context }, { type: "text", text: message }],
    }, {
      createMessage: (params) => anthropic.beta.messages.create(params),
      runTool: (name, input) => runTool(name, input, (fn, args) => db.rpc(fn, args)),
      model,
      effort,
    });

    await db.from("ai_messages").insert({
      role: "assistant",
      content: result.reply,
      tool_calls: result.toolCalls.length ? result.toolCalls : null,
    });

    return json({ reply: result.reply, device_actions: result.deviceActions, tool_calls: result.toolCalls });
  } catch (err) {
    // Log details server-side only; the app gets a generic error.
    console.error("ai-agent failed", err);
    const status = err instanceof Anthropic.RateLimitError ? 429 : 502;
    return json({ error: status === 429 ? "rate_limited" : "agent_failed" }, status);
  }
});

// deno-lint-ignore no-explicit-any
type Db = SupabaseClient<any, "public", "public", any, any>;

async function contextLine(db: Db) {
  const { data: settings } = await db.from("user_settings").select("timezone, default_notify_mode").maybeSingle();
  const tz = (settings as { timezone?: string } | null)?.timezone ?? "UTC";
  const notify = (settings as { default_notify_mode?: string } | null)?.default_notify_mode ?? "app";
  return `Now: ${new Date().toISOString()} (user timezone ${tz}; default notify mode ${notify}).`;
}

/** One-shot task modes (briefing, ...): scoped tools, a structured result, no chat history. */
async function runTask(mode: string, params: Record<string, unknown>, db: Db) {
  const task = TASKS[mode];
  if (!task) return json({ error: "unknown_mode" }, 400);
  try {
    const result = await runAgent([], {
      role: "user",
      content: [{ type: "text", text: await contextLine(db) }, { type: "text", text: task.prompt(params) }],
    }, {
      createMessage: (p) => anthropic.beta.messages.create(p),
      runTool: (name, input) =>
        (task.tools as string[]).includes(name)
          ? runTool(name, input, (fn, args) => db.rpc(fn, args))
          : Promise.resolve({ ok: false as const, error: `tool_not_allowed: ${name}` }),
      model,
      effort: task.effort ?? effort,
      system: `${SYSTEM_PROMPT}\n\n${task.instructions}`,
      tools: toolsFor(task),
      finish: task.finish,
    });
    if (result.result === undefined) return json({ error: "task_incomplete", reply: result.reply }, 502);
    const final = task.after
      ? await task.after({ result: result.result, toolResults: result.toolResults ?? [], params, db })
      : result.result;
    return json({ result: final, reply: result.reply, device_actions: result.deviceActions, tool_calls: result.toolCalls,
      tool_results: result.toolResults ?? [] });
  } catch (err) {
    console.error(`ai-agent task ${mode} failed`, err);
    const status = err instanceof Anthropic.RateLimitError ? 429 : 502;
    return json({ error: status === 429 ? "rate_limited" : "agent_failed" }, status);
  }
}
