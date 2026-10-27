// Tool definitions for the ai-agent Edge Function.
// One zod schema per tool is the single source of truth: it produces the JSON Schema Claude sees
// and validates Claude's arguments before anything touches the database.
import { z } from "npm:zod@4.6.7";

const dateTime = z.iso.datetime({ offset: true }).describe("ISO 8601 with timezone offset, e.g. 2026-10-27T09:00:00+01:00");
const areaRef = z.string().min(1).describe("Area name (case-insensitive) or id");
const uuid = z.uuid();
const priorities = { none: 0, low: 1, medium: 2, high: 3 } as const;
const notifyMode = z.enum(["app", "reminders_app", "none"]);

// A database call: the Postgres function name and its named arguments.
export type Rpc = { fn: string; args: Record<string, unknown> };
// Something the app must do on-device (EventKit writes never happen server-side).
export type DeviceAction = { type: "reminder.upsert" | "reminder.delete"; reminder: unknown };

type ToolSpec<S extends z.ZodType> = {
  description: string;
  schema: S;
  toRpc: (input: z.infer<S>) => Rpc;
  deviceAction?: (result: any) => DeviceAction | null;
};

const tool = <S extends z.ZodType>(spec: ToolSpec<S>) => spec;

// Reminder results carry the row; the app mirrors it into Apple Reminders.
const reminderAction = (result: any): DeviceAction | null =>
  result?.reminder
    ? { type: result.action === "deleted" || result.action === "pending_delete" ? "reminder.delete" : "reminder.upsert", reminder: result.reminder }
    : null;

export const TOOLS = {
  create_area: tool({
    description: "Create a life area (e.g. Sleep, Finance). Returns the existing area if one with that name already exists.",
    schema: z.strictObject({
      name: z.string().trim().min(1).max(60),
      kind: z.enum(["gym", "tasks", "goals", "habits", "finance", "dev", "custom"]).default("custom"),
      icon: z.string().max(60).optional().describe("SF Symbol name, e.g. bed.double"),
    }),
    toRpc: (i) => ({ fn: "ai_create_area", args: { p_name: i.name, p_kind: i.kind, p_icon: i.icon ?? null } }),
  }),

  upsert_item: tool({
    description:
      "Create or update an item (task, goal, habit, list entry). Pass id to update a known item; without id, an open item with the same title in the area is updated instead of duplicated. Only the fields you pass change; pass null to clear due.",
    schema: z.strictObject({
      id: uuid.optional(),
      area: areaRef.optional().describe("Required when creating"),
      title: z.string().trim().min(1).max(200).optional(),
      status: z.enum(["not_started", "in_progress", "done", "blocked"]).optional(),
      progress: z.number().int().min(0).max(100).optional(),
      priority: z.enum(["none", "low", "medium", "high"]).optional(),
      due: dateTime.nullable().optional(),
      recurrence: z.string().max(200).nullable().optional().describe("RRULE, e.g. FREQ=DAILY"),
      tags: z.array(z.string().max(40)).max(20).optional(),
      parent_id: uuid.nullable().optional().describe("Goal this item is a milestone of"),
      data: z.record(z.string(), z.unknown()).optional().describe("Extra fields, merged into existing data"),
    }).refine((i) => i.id || (i.area && i.title), { message: "Pass id, or area and title" }),
    toRpc: (i) => {
      const { priority, ...rest } = i;
      return { fn: "ai_upsert_item", args: { p: priority ? { ...rest, priority: priorities[priority] } : rest } };
    },
  }),

  complete_item: tool({
    description: "Mark an item done.",
    schema: z.strictObject({ id: uuid }),
    toRpc: (i) => ({ fn: "ai_complete_item", args: { p_id: i.id } }),
  }),

  delete_item: tool({
    description: "Delete an item permanently. Only when the user clearly asks to delete it.",
    schema: z.strictObject({ id: uuid }),
    toRpc: (i) => ({ fn: "ai_delete_item", args: { p_id: i.id } }),
  }),

  log_entry: tool({
    description: "Add a timestamped note to an area (what happened, a habit completion via item_id, a meal).",
    schema: z.strictObject({
      area: areaRef,
      note: z.string().trim().min(1).max(2000),
      item_id: uuid.optional(),
      logged_at: dateTime.optional().describe("Defaults to now"),
    }),
    toRpc: (i) => ({ fn: "ai_log_entry", args: { p_area: i.area, p_note: i.note, p_item_id: i.item_id ?? null, p_logged_at: i.logged_at ?? null } }),
  }),

  record_metric: tool({
    description: "Record a number in a time series (bodyweight, sleep_hours, savings, expense). Only record values the user stated.",
    schema: z.strictObject({
      area: areaRef,
      name: z.string().trim().min(1).max(60).describe("snake_case, e.g. bodyweight"),
      value: z.number().finite(),
      unit: z.string().max(20).optional(),
      recorded_at: dateTime.optional().describe("Defaults to now"),
    }),
    toRpc: (i) => ({
      fn: "ai_record_metric",
      args: { p_area: i.area, p_name: i.name, p_value: i.value, p_unit: i.unit ?? null, p_recorded_at: i.recorded_at ?? null },
    }),
  }),

  query_area: tool({
    description: "Read an area's items, logs and metrics in a date range (default last 30 days). Gym areas also return Hevy workouts with per-exercise sets, top weight and volume.",
    schema: z.strictObject({
      area: areaRef,
      from: dateTime.optional(),
      to: dateTime.optional(),
      status: z.enum(["not_started", "in_progress", "done", "blocked"]).optional(),
      tag: z.string().optional(),
      limit: z.number().int().min(1).max(200).optional(),
    }),
    toRpc: (i) => ({
      fn: "ai_query_area",
      args: { p_area: i.area, p_from: i.from ?? null, p_to: i.to ?? null, p_status: i.status ?? null, p_tag: i.tag ?? null, p_limit: i.limit ?? 50 },
    }),
  }),

  get_dashboard_summary: tool({
    description: "Overview of all visible areas (or one): open and overdue items, recent activity, latest metrics.",
    schema: z.strictObject({ area: areaRef.optional() }),
    toRpc: (i) => ({ fn: "ai_dashboard_summary", args: { p_area: i.area ?? null } }),
  }),

  get_daily_briefing: tool({
    description: "Today in the user's timezone: what's due, what's overdue, reminders today, what was done yesterday.",
    schema: z.strictObject({}),
    toRpc: () => ({ fn: "ai_daily_briefing", args: {} }),
  }),

  create_reminder: tool({
    description: "Create a reminder; the app adds it to Apple Reminders. Needs a time: if the user gave none, ask instead of calling this.",
    schema: z.strictObject({
      title: z.string().trim().min(1).max(200),
      remind_at: dateTime,
      repeat: z.string().max(200).optional().describe("RRULE, e.g. FREQ=WEEKLY;BYDAY=MO"),
      area: areaRef.optional(),
      item_id: uuid.optional(),
      notify_mode: notifyMode.optional().describe("Omit to use the user's default"),
      notes: z.string().max(2000).optional(),
    }),
    toRpc: (i) => ({ fn: "ai_create_reminder", args: { p: i } }),
    deviceAction: reminderAction,
  }),

  update_reminder: tool({
    description: "Change a reminder. Only the fields you pass change.",
    schema: z.strictObject({
      id: uuid,
      title: z.string().trim().min(1).max(200).optional(),
      remind_at: dateTime.nullable().optional(),
      repeat: z.string().max(200).nullable().optional(),
      area: areaRef.nullable().optional(),
      notify_mode: notifyMode.optional(),
      notes: z.string().max(2000).nullable().optional(),
    }),
    toRpc: (i) => ({ fn: "ai_update_reminder", args: { p: i } }),
    deviceAction: reminderAction,
  }),

  complete_reminder: tool({
    description: "Mark a reminder done.",
    schema: z.strictObject({ id: uuid }),
    toRpc: (i) => ({ fn: "ai_complete_reminder", args: { p_id: i.id } }),
    deviceAction: reminderAction,
  }),

  delete_reminder: tool({
    description: "Delete a reminder. Only when the user clearly asks to delete it.",
    schema: z.strictObject({ id: uuid }),
    toRpc: (i) => ({ fn: "ai_delete_reminder", args: { p_id: i.id } }),
    deviceAction: reminderAction,
  }),

  list_reminders: tool({
    description: "List open reminders, optionally for one area or a time range.",
    schema: z.strictObject({
      area: areaRef.optional(),
      from: dateTime.optional(),
      to: dateTime.optional(),
      include_done: z.boolean().optional(),
    }),
    toRpc: (i) => ({
      fn: "ai_list_reminders",
      args: { p_area: i.area ?? null, p_from: i.from ?? null, p_to: i.to ?? null, p_include_done: i.include_done ?? false },
    }),
  }),

  capture: tool({
    description: "Park a thought in the inbox to sort later (when the user says to note something without deciding where it goes).",
    schema: z.strictObject({
      text: z.string().trim().min(1).max(2000),
      source: z.enum(["text", "voice", "siri", "widget"]).default("text"),
    }),
    toRpc: (i) => ({ fn: "ai_capture", args: { p_text: i.text, p_source: i.source } }),
  }),

  submit_checkin: tool({
    description: "Save a morning or evening check-in (mood and energy 1-5). Submitting again the same day updates it.",
    schema: z.strictObject({
      type: z.enum(["morning", "evening"]),
      mood: z.number().int().min(1).max(5).optional(),
      energy: z.number().int().min(1).max(5).optional(),
      wins: z.string().max(1000).optional().describe("Evening: wins. Morning: top priority."),
      notes: z.string().max(2000).optional(),
    }),
    toRpc: (i) => ({ fn: "ai_submit_checkin", args: { p: i } }),
  }),

  get_weekly_review: tool({
    description: "Facts for a week (default: this week): per area completed and missed items, logs, metric stats, habit days; workouts; check-in averages.",
    schema: z.strictObject({ week_start: z.iso.date().optional().describe("Monday, YYYY-MM-DD") }),
    toRpc: (i) => ({ fn: "ai_weekly_review", args: { p_week_start: i.week_start ?? null } }),
  }),

  get_day_digest: tool({
    description: "Everything from one day (default today): completed items, logs, metrics, health, workouts, check-ins.",
    schema: z.strictObject({ date: z.iso.date().optional() }),
    toRpc: (i) => ({ fn: "ai_day_digest", args: { p_date: i.date ?? null } }),
  }),
} satisfies Record<string, ToolSpec<any>>;

export type ToolName = keyof typeof TOOLS;

// zod emits long regexes for uuid/date-time; `format` says the same in far fewer tokens and zod
// still enforces the exact rule.
const stripPatterns = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(stripPatterns)
  : v && typeof v === "object" ? Object.fromEntries(Object.entries(v).filter(([k]) => k !== "pattern").map(([k, x]) => [k, stripPatterns(x)]))
  : v;

// Tool list in the shape the Messages API expects. Built once, so it is byte-stable (prompt cache).
export const TOOL_DEFINITIONS = Object.entries(TOOLS).map(([name, t]) => {
  const { $schema: _ignored, ...input_schema } = stripPatterns(z.toJSONSchema(t.schema, { io: "input" })) as Record<string, unknown>;
  return { name, description: t.description, input_schema: { type: "object" as const, ...input_schema } };
});

export type ToolOutcome = { ok: true; result: unknown; deviceAction: DeviceAction | null } | { ok: false; error: string };

// Validate, then run. `rpc` performs the database call as the signed-in user.
export async function runTool(
  name: string,
  input: unknown,
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string } | null }>,
): Promise<ToolOutcome> {
  const spec = (TOOLS as Record<string, ToolSpec<any>>)[name];
  if (!spec) return { ok: false, error: `unknown_tool: ${name}` };

  const parsed = spec.schema.safeParse(input);
  if (!parsed.success) return { ok: false, error: `invalid_arguments: ${z.prettifyError(parsed.error)}` };

  const call = spec.toRpc(parsed.data);
  const { data, error } = await rpc(call.fn, call.args);
  if (error) return { ok: false, error: error.message };
  return { ok: true, result: data, deviceAction: spec.deviceAction?.(data) ?? null };
}
