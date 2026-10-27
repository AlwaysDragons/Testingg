// Task modes: one-shot jobs the app asks for (daily briefing, ...). Each has its own instructions,
// a narrower tool list and a schema-validated finish tool that returns a structured result.
// Task runs are not saved to the chat history.
import { z } from "npm:zod@4.6.7";
import type { FinishTool } from "./agent.ts";
import { TOOL_DEFINITIONS, type ToolName } from "./tools.ts";

export const READ_ONLY_TOOLS: ToolName[] = [
  "query_area", "get_dashboard_summary", "get_daily_briefing", "list_reminders", "get_weekly_review", "get_day_digest", "get_streaks",
  "get_budget_status", "list_subscriptions",
];

// deno-lint-ignore no-explicit-any
type Db = any;

/** What a task can do after it finishes (e.g. mark the capture sorted). Its return value is sent as `result`. */
export type AfterTask = (ctx: {
  result: unknown;
  toolResults: { name: string; result: unknown }[];
  params: Record<string, unknown>;
  db: Db;
}) => Promise<unknown>;

export type Task = {
  /** Appended to the base system prompt. */
  instructions: string;
  /** The user turn, built from the request's params. */
  prompt: (params: Record<string, unknown>) => string;
  tools: ToolName[];
  finish: FinishTool;
  effort?: "low" | "medium" | "high";
  after?: AfterTask;
};

/** Rows a task created, from its tool results (for undo). Updates of existing rows are not included. */
export function createdRows(toolResults: { name: string; result: unknown }[]) {
  const out: { table: string; id: string }[] = [];
  for (const { result } of toolResults) {
    // deno-lint-ignore no-explicit-any
    const r = result as any;
    if (r?.action === "created" && r.item?.id) out.push({ table: "items", id: r.item.id });
    else if (r?.action === "created" && r.reminder?.id) out.push({ table: "reminders", id: r.reminder.id });
    else if (r?.action === "created" && r.area?.id) out.push({ table: "areas", id: r.area.id });
    else if (r?.action === "logged" && r.log?.id) out.push({ table: "logs", id: r.log.id });
    else if (r?.action === "recorded" && r.metric?.id) out.push({ table: "metrics", id: r.metric.id });
  }
  return out;
}

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

const WRITE_TOOLS: ToolName[] = ["create_area", "upsert_item", "log_entry", "record_metric", "create_reminder", "log_expense"];

TASKS.capture = {
  instructions: `Task: sort one quick capture into the right place, then call finish_capture.
- Decide what it is: a task (upsert_item), a reminder (create_reminder; only if it has a time, otherwise make it a task with a due date if one is given), an expense (log_expense with the amount and a category), a number to track (record_metric), or a note (log_entry).
- Use an existing area when one fits (check get_dashboard_summary). Only create an area if nothing fits and the capture clearly starts something new.
- Never invent amounts, dates or times. If it's too unclear to sort, call finish_capture with kind "unsorted".
- summary: at most 8 words, e.g. "Task in Home: buy milk".`,
  prompt: (p) => `Capture (${String(p.source ?? "text")}): ${String(p.text ?? "")}`,
  tools: [...READ_ONLY_TOOLS, ...WRITE_TOOLS],
  finish: finishTool("finish_capture", "Report where the capture landed.", z.strictObject({
    kind: z.enum(["task", "reminder", "expense", "metric", "note", "unsorted"]),
    area: z.string().max(60).optional().describe("Area name it went to"),
    item_id: z.uuid().optional(),
    summary: z.string().trim().min(1).max(120),
  })),
  effort: "low",
  after: async ({ result, toolResults, params, db }) => {
    // deno-lint-ignore no-explicit-any
    const r = result as any;
    const created = createdRows(toolResults);
    const id = typeof params.capture_id === "string" ? params.capture_id : null;
    let areaId: string | null = null;
    if (r.area) {
      const { data } = await db.from("areas").select("id").ilike("name", r.area).limit(1);
      areaId = data?.[0]?.id ?? null;
    }
    const sorted = r.kind !== "unsorted" && created.length > 0;
    if (id) {
      await db.from("captures").update({
        status: sorted ? "sorted" : "inbox",
        routed_area_id: sorted ? areaId : null,
        routed_item_id: sorted ? (r.item_id ?? created.find((c) => c.table === "items")?.id ?? null) : null,
        data: { created, kind: r.kind, summary: r.summary },
      }).eq("id", id);
    }
    return { ...r, sorted, area_id: areaId, created };
  },
};

TASKS.weekly_review = {
  instructions: `Task: write the user's weekly review. Call get_weekly_review (pass week_start if given), then call submit_review.
- summary: 2 sentences max on how the week went.
- wins / misses: short phrases, only from completed / missed items, habit days and metrics in the tool result. Up to 5 each.
- focus: one sentence suggesting next week's focus.
- suggestions: up to 5 concrete items for next week, each with an existing area name and a short title. Only suggest; don't create anything.
- Never invent numbers; quote only what the tool returned.`,
  prompt: (p) => `Weekly review${typeof p.week_start === "string" ? ` for the week starting ${p.week_start}` : ""}.`,
  tools: READ_ONLY_TOOLS,
  finish: finishTool("submit_review", "Return the weekly review.", z.strictObject({
    summary: z.string().trim().min(1).max(400),
    wins: z.array(z.string().max(120)).max(5),
    misses: z.array(z.string().max(120)).max(5),
    focus: z.string().trim().max(240),
    suggestions: z.array(z.strictObject({ area: z.string().max(60), title: z.string().trim().min(1).max(120) })).max(5),
  })),
  effort: "medium",
};

TASKS.journal = {
  instructions: `Task: write the user's journal entry for one day. Call get_day_digest for that date, then call submit_journal.
- content: first person, past tense, 3-6 short sentences, plain and warm, no headings or emoji. Mention what got done, workouts, how they felt (check-ins) and anything logged. Use only facts from the digest; if the day is empty, say it was a quiet day in one sentence.`,
  prompt: (p) => `Journal for ${typeof p.date === "string" ? p.date : "today"}.`,
  tools: ["get_day_digest"],
  finish: finishTool("submit_journal", "Return the journal entry.", z.strictObject({
    content: z.string().trim().min(1).max(2000),
  })),
  effort: "low",
  after: async ({ result, params, db }) => {
    // deno-lint-ignore no-explicit-any
    const r = result as any;
    const date = typeof params.date === "string" ? params.date : new Date().toISOString().slice(0, 10);
    const { data } = await db.rpc("ai_save_journal", { p_date: date, p_content: r.content });
    return { content: r.content, saved: data?.action === "saved" };
  },
};

TASKS.plan_day = {
  instructions: `Task: draft a time-blocked plan for the rest of the user's day, then call submit_plan.
- Use get_daily_briefing and query_area to see what's due and important.
- Place blocks only inside the free slots the device sent; never overlap calendar events. Leave short breaks.
- Prefer overdue and high-priority items; use the item's title and pass item_id when a block is for an item.
- start/end: ISO 8601 with the user's timezone offset. Up to 8 blocks. note: one short sentence, optional.
- This is a draft: the user approves before anything is written to their calendar.`,
  prompt: (p) => `Plan my day.\n${typeof p.device_context === "string" ? p.device_context : "No calendar data."}`,
  tools: READ_ONLY_TOOLS,
  finish: finishTool("submit_plan", "Return the drafted plan.", z.strictObject({
    blocks: z.array(z.strictObject({
      title: z.string().trim().min(1).max(120),
      start: z.iso.datetime({ offset: true }),
      end: z.iso.datetime({ offset: true }),
      item_id: z.uuid().optional(),
    })).max(8),
    note: z.string().max(240).optional(),
  })),
  effort: "medium",
};

TASKS.next_action = {
  instructions: `Task: answer "What should I do now?". Look at what's due or overdue (get_daily_briefing), habits left (get_streaks) and today's latest check-in energy (in the briefing), plus the calendar gap the device sent. Then call submit_next.
- action: the single best next thing that fits the time until the next event and the user's energy (low energy → something small or a habit). Include item_id when it's an existing item, and minutes (how long it takes).
- alternates: exactly 2 other options, same shape.
- why: one short sentence. Never invent items; only use items from the tools.`,
  prompt: (p) => `What should I do now?\n${typeof p.device_context === "string" ? p.device_context : ""}`,
  tools: READ_ONLY_TOOLS,
  finish: finishTool("submit_next", "Return the suggestion.", z.strictObject({
    action: z.strictObject({ title: z.string().trim().min(1).max(120), item_id: z.uuid().optional(), area: z.string().max(60).optional(), minutes: z.number().int().min(1).max(480).optional() }),
    alternates: z.array(z.strictObject({ title: z.string().trim().min(1).max(120), item_id: z.uuid().optional(), area: z.string().max(60).optional(), minutes: z.number().int().min(1).max(480).optional() })).max(2),
    why: z.string().trim().max(200),
  })),
  effort: "low",
};

export function toolsFor(task: Task) {
  return TOOL_DEFINITIONS.filter((t) => (task.tools as string[]).includes(t.name));
}
