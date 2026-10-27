// Unit tests (no network, no database): deno test supabase/functions/ai-agent
import { assert, assertEquals } from "jsr:@std/assert@1.0.13";
import { historyFrom, runAgent } from "./agent.ts";
import { runTool, TOOL_DEFINITIONS } from "./tools.ts";

const ID = "6f1c2b1e-3d4a-4f5b-9c6d-7e8f9a0b1c2d";

Deno.test("tool definitions are plain JSON Schema objects", () => {
  assertEquals(TOOL_DEFINITIONS.length, 14);
  for (const t of TOOL_DEFINITIONS) {
    assertEquals(t.input_schema.type, "object");
    assert(!("$schema" in t.input_schema), t.name);
    assert(t.description.length > 10, t.name);
  }
});

Deno.test("invalid arguments never reach the database", async () => {
  let called = false;
  const rpc = () => { called = true; return Promise.resolve({ data: null, error: null }); };
  const bad = [
    ["record_metric", { area: "Gym", name: "bodyweight", value: "82" }], // string, not number
    ["upsert_item", { title: "No area" }],                               // needs id or area+title
    ["complete_item", { id: "not-a-uuid" }],
    ["create_reminder", { title: "Call mom" }],                          // no time
    ["create_area", { name: "Sleep", extra: 1 }],                        // unknown key
    ["drop_tables", {}],
  ] as const;
  for (const [name, input] of bad) {
    const out = await runTool(name, input, rpc);
    assert(!out.ok, name);
  }
  assert(!called);
});

Deno.test("arguments map to the right database call", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  const rpc = (fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve({ data: { action: "created", reminder: { id: ID } }, error: null });
  };
  await runTool("upsert_item", { area: "Tasks", title: "Ship", priority: "high", due: null }, rpc);
  assertEquals(calls[0], ["ai_upsert_item", { p: { area: "Tasks", title: "Ship", priority: 3, due: null } }]);

  const out = await runTool("create_reminder", { title: "Call mom", remind_at: "2026-10-28T09:00:00+01:00" }, rpc);
  assert(out.ok && out.deviceAction?.type === "reminder.upsert");
});

Deno.test("database errors come back as tool errors", async () => {
  const rpc = () => Promise.resolve({ data: null, error: { message: "area_not_found: Sleep" } });
  const out = await runTool("log_entry", { area: "Sleep", note: "7h" }, rpc);
  assertEquals(out, { ok: false, error: "area_not_found: Sleep" });
});

Deno.test("loop runs tools, passes assistant content back unchanged, returns final text", async () => {
  const requests: any[] = [];
  const thinking = { type: "thinking", thinking: "", signature: "sig" };
  const replies = [
    {
      stop_reason: "tool_use",
      content: [thinking, { type: "tool_use", id: "tu1", name: "complete_item", input: { id: ID } }],
    },
    { stop_reason: "end_turn", content: [{ type: "text", text: "Done: Ship." }] },
  ];
  const result = await runAgent([], { role: "user", content: "finish ship" }, {
    createMessage: (p) => { requests.push(structuredClone(p)); return Promise.resolve(replies.shift() as any); },
    runTool: () => Promise.resolve({ ok: true, result: { action: "completed" }, deviceAction: null }),
  });

  assertEquals(result.reply, "Done: Ship.");
  assertEquals(result.toolCalls, [{ name: "complete_item", input: { id: ID }, ok: true }]);
  const second = requests[1].messages;
  assertEquals(second[1], { role: "assistant", content: [thinking, { type: "tool_use", id: "tu1", name: "complete_item", input: { id: ID } }] });
  assertEquals(second[2].content[0].tool_use_id, "tu1");
  assertEquals(requests[0].model, "claude-sonnet-5-5");
  assertEquals(requests[0].thinking, { type: "adaptive" });
  assert(!("tool_choice" in requests[0]));
});

Deno.test("failed tools are reported with is_error and the loop continues", async () => {
  const requests: any[] = [];
  const replies = [
    { stop_reason: "tool_use", content: [{ type: "tool_use", id: "tu1", name: "log_entry", input: { area: "X", note: "n" } }] },
    { stop_reason: "end_turn", content: [{ type: "text", text: "There is no area called X. Create it?" }] },
  ];
  const result = await runAgent([], { role: "user", content: "log n to X" }, {
    createMessage: (p) => { requests.push(structuredClone(p)); return Promise.resolve(replies.shift() as any); },
    runTool: () => Promise.resolve({ ok: false, error: "area_not_found: X" }),
  });
  assertEquals(requests[1].messages[2].content[0].is_error, true);
  assertEquals(result.toolCalls[0].error, "area_not_found: X");
});

Deno.test("refusal and runaway loops end cleanly", async () => {
  const refused = await runAgent([], { role: "user", content: "x" }, {
    createMessage: () => Promise.resolve({ stop_reason: "refusal", content: [] } as any),
    runTool: () => Promise.reject(new Error("not called")),
  });
  assertEquals(refused.stopReason, "refusal");

  const looping = await runAgent([], { role: "user", content: "x" }, {
    createMessage: () => Promise.resolve({ stop_reason: "tool_use", content: [{ type: "tool_use", id: "t", name: "get_daily_briefing", input: {} }] } as any),
    runTool: () => Promise.resolve({ ok: true, result: {}, deviceAction: null }),
  });
  assertEquals(looping.stopReason, "max_steps");
  assertEquals(looping.toolCalls.length, 8);
});

Deno.test("history keeps alternating roles and starts with the user", () => {
  const h = historyFrom([
    { role: "assistant", content: "orphan" },
    { role: "user", content: "a" },
    { role: "user", content: "b" },
    { role: "tool", content: "ignored" },
    { role: "assistant", content: "c" },
    { role: "assistant", content: null },
  ]);
  assertEquals(h, [{ role: "user", content: "a\n\nb" }, { role: "assistant", content: "c" }]);
});
