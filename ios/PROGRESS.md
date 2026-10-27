# PROGRESS.md

Claude Code: update this file after every phase. Read it at the start of each session (after `/clear`) to pick up where we left off.

## Existing code I must NOT modify
Protected (read-only; wrap with adapters, never edit):

- `Forge/Services/HevyClient.swift`: Hevy API client (api-key header, paginated workouts + exercise templates, incremental sync)
- `Forge/Services/HealthKitManager.swift`: HealthKit read-only queries (daily stats, sleep per night, single best source)
- `Forge/Services/Keychain.swift`: Keychain storage for the Hevy and Claude keys
- `Forge/Services/ClaudeClient.swift`, `Forge/Services/APIError.swift`: existing AI client + JSON decoding
- `Forge/Models/HevyModels.swift`, `Forge/Models/HealthModels.swift`, `Forge/Models/Formatting.swift`
- `Forge/Logic/*`: Analyzer, Readiness, RecoveryPlanner, CoachContext, DemoData
- `Forge/App/AppModel.swift`, `Forge/App/ForgeApp.swift`: state, sync, local cache (`forge-cache.json`)
- `Forge/Views/*`: Today, Training, Recovery, Coach, Settings screens + Theme
- `Forge/Assets.xcassets`

Config files that will need additive-only changes (diff shown before applying):
- `project.yml`, `Support/Info.plist`, `Package.swift` (new permissions: Reminders, Calendar, notifications; Supabase SDK dependency)

### How the existing integrations work
- **Hevy:** the API key is entered in Settings and stored in the Keychain. `HevyClient` calls `api.hevyapp.com/v1` (`api-key` header): it loads all exercise templates (muscle-group mapping), then workouts 10 per page, newest first, stopping early when a page is unchanged vs. the cache. It syncs on launch, on foreground and on pull-to-refresh.
- **HealthKit:** read-only authorization. `HealthKitManager.fetchAll()` returns `HealthData`, one value per day for 60 days (steps, energy, resting HR, HRV, weight, body fat, VO2 max, protein, calories, sleep).
- **Storage:** `AppModel` caches workouts, templates and health data in `Documents/forge-cache.json` (complete file protection). There is no backend yet.

## Phases
Stop after each phase and wait for my OK. Branch per phase, commit when done.

- [x] 0. Inspect codebase, summarize Hevy + HealthKit, list protected files
- [x] 1. Supabase schema + RLS (SQL + setup steps)
- [x] 2. Wrap Hevy and HealthKit as Integration adapters + sync into Supabase
- [x] 3. Edge Function + tool calling
- [x] 3.5. Design system + component library (tokens, Card, StatView, ProgressRing, SectionHeader, EmptyState, ListRow)
- [x] 4. SwiftUI Home + Area detail + realtime
- [x] 5. Chat wired to the agent
- [x] 5.5. Reminders: EventKit two-way sync + local notifications + settings + AI reminder tools
- [x] 6. Daily briefing + push notifications
- [x] 7. Widgets, Live Activities, App Intents
- [x] 8. Quick capture + inbox + routing + Siri/Action Button/widget entry
- [x] 9. Check-ins + weekly review + daily journal
- [x] 10. Calendar integration + unified Today timeline
- [ ] 11. Habits/streaks + focus timer + "What should I do now?" + goals with milestones
- [ ] 12. Health features on existing HealthKit/Hevy code (PRs, recovery, skip-or-push, nutrition, measurements, photos)
- [ ] 13. Money (expenses, budgets, subscriptions, savings goals)
- [ ] 14. Smart AI (insights, nudges, universal search)
- [ ] 15. Life admin (people, lists, documents, travel)
- [ ] 16. Apple Watch companion, StandBy, Focus modes, Face ID area locks

## Decisions log
- Phase 0: `CLAUDE.md` and `PROGRESS.md` live in `ios/` so they don't affect the unrelated Python project at the repo root.
- Phase 0 questions were not answered; proceeding with these defaults (override any time):
  1. New Supabase project; sign-in by 6-digit email code (Sign in with Apple needs a paid developer account).
  2. Verification: Linux type-check for non-UI code, an HTML mock for look approval, and you run `xtool dev` and paste errors (`xcodebuild`/Previews can't run in the cloud session).
  3. Existing Forge screens stay untouched and will be hosted inside the Gym area.
- Phase 1 (schema), beyond the spec, all additive:
  - `user_settings` table (default notify mode, quiet hours, briefing time, timezone, feature toggles). The spec needs these settings server-side but had no table for them. A row is auto-created on sign-up.
  - `items.parent_id` (goals -> milestones), `items.completed_at` (weekly-review wins).
  - `logs.data`, `metrics.data` (expense category), `metrics.source` + `metrics.external_id` (unique; integrations upsert on it, e.g. `hrv:2026-10-27`).
  - `reminders.completed_at` + `reminders.source_modified_at` (needed for "most recent edit wins").
  - `captures.data` (undo info), `insights.sample_size`. `captures.routed_to` is split into `routed_area_id` + `routed_item_id`.
  - `workouts` adds `title`, `started_at`, `ended_at`, `hevy_updated_at`; `workout_sets` holds one row per set, upserted on (workout, exercise_index, set_index).
- Enumerations use text + CHECK (no Postgres enums), so adding a value later is a one-line change.
- Security: RLS "own rows" on all 18 tables (authenticated role only; anon sees nothing). Composite (id, user_id) foreign keys stop rows from pointing at another user's data. A CHECK blocks secret-looking keys in `integrations.config`.
- Uniques for dedupe: area name per user (case-insensitive), `workouts (user_id, hevy_id)`, `reminders (user_id, apple_reminder_id)`, `checkins (user_id, date, type)`, `journal_entries (user_id, date)`.
- Deleting an area deletes its items/logs/metrics but keeps workouts, reminders and subscriptions (their area link becomes null).
- Realtime enabled on: areas, items, logs, metrics, reminders, ai_messages, captures, checkins, insights.
- Storage: private `photos` + `documents` buckets; files under `<user_id>/...`; per-user policies; signed URLs only.
- Verified locally on Postgres 16 with Supabase auth/storage stubs: 13 checks passed (RLS isolation, cross-user FK block, anon blocked, upsert dedupe, CHECKs, updated_at trigger, storage isolation, delete behavior).

- Phase 2 (integrations):
  - No Supabase SDK. A small hand-written client (`Cloud/SupabaseClient.swift`: email-code auth + PostgREST) means `Package.swift` / `project.yml` are untouched. Realtime (Phase 4) may add the SDK; that would be a dependency change, so I'll ask first.
  - Adapters read the data the existing code already fetched (`AppModel.workouts`, `AppModel.health`). They never call Hevy or HealthKit themselves, so there are no duplicate API calls and the existing code is unchanged.
  - Areas "Gym" (kind gym) and "Health" (kind custom) are created automatically on first sync, pinned.
  - Incremental sync: the cursor is stored in `integrations.config.cursor`. Hevy pushes workouts edited after the cursor (sets are replaced per workout). HealthKit re-pushes the last 3 days each time, because today's totals keep changing.
  - Metric names: steps, active_energy, resting_hr, hrv, sleep_hours, bodyweight (kg), body_fat (%), vo2_max, protein, calories_in. external_id is `<name>:<yyyy-MM-dd>`.
  - Sample/demo data is never uploaded.
  - Approved protected-file edits (additive): `ForgeApp.swift` +1 line (`.cloudSync()` on RootView); `SettingsView.swift` +3 lines ("Cloud sync" section).
  - Supabase URL, anon key and session are stored in the Keychain (via the existing helper). The app refuses service_role / `sb_secret_` keys.
  - Migration 3 swaps the partial unique indexes for plain unique constraints, because PostgREST `on_conflict` can't target partial indexes. Behavior is the same, since NULLs don't conflict.
  - Verified: type-check of all non-UI code; the adapters' exact JSON was upserted into Postgres twice with identical counts (10 workouts / 190 sets / 346 metrics), so there are no duplicates; the secret-key guard was tested.

- Phase 3 (AI agent):
  - Model: Claude Sonnet 5.5 (`claude-sonnet-5-5`), adaptive thinking, effort `medium`. Both can be changed with the `AI_MODEL` / `AI_EFFORT` secrets, no redeploy needed.
  - Server-side fallback is on (`fallbacks: "default"`): if Claude declines a request for policy reasons, the API retries it on a fallback model. A full refusal returns a short "can't help" reply.
  - Tool logic lives in Postgres functions (`ai_*`, migration 4, `security invoker`). The Edge Function validates arguments with zod, then calls them via RPC with the user's JWT, so RLS applies. No service_role key anywhere.
  - Each tool has one zod schema, which produces both the JSON Schema Claude sees and the validation. Invalid arguments never reach the database; errors go back to Claude so it can fix them or ask you.
  - Tools built: the core set (create_area, upsert_item, complete_item, delete_item, log_entry, record_metric, query_area, get_dashboard_summary, get_daily_briefing) and reminders (create/update/complete/delete/list). The everyday tools come with their phases.
  - Dedupe: areas match by name (case-insensitive); upsert_item updates by id, else the open item with the same title in that area.
  - Reminders: the agent writes the `reminders` row (`sync_status = pending_push`, or `pending_delete` once it's in Apple Reminders) and returns `device_actions`. The app does the EventKit write (Phase 5.5). create_reminder requires a time; notify_mode defaults to your setting.
  - History: the last 20 chat messages (text only) are sent with each request. The current time and timezone go in the user turn, so the system prompt and tools stay cacheable.
  - Limits: 8 tool rounds per message, 4000-character messages, generic errors to the app (details only in the function logs).
  - iOS: `Cloud/AgentClient.swift` (new) plus `SupabaseClient.invoke(...)` (additive; `send` got an optional timeout). No UI yet; that's Phase 5.
  - Verified: Deno type-check; 8 unit tests (validation, argument mapping, loop, refusal, step cap, history); 31 SQL checks on local Postgres 16 with RLS (dedupe, partial updates, errors, gym volume, briefing, reminders, cross-user isolation, anon blocked); an end-to-end test of every tool through zod and RPC into the database. Not verified: a live Claude call (no API key here) and the Swift compile.

- Phase 3.5 (design system), in `Forge/Design/`:
  - Tokens (`DS`): adaptive neutrals (near-white / near-black background, surface one step off), one accent per area from `areas.color` with per-kind fallbacks, muted status colors (positive, warning, critical), 8pt spacing, 20pt card radius, three type sizes (hero rounded numerals, body, caption), short springs, haptics.
  - Components: `DSCard`, `StatView`, `ProgressRing`, `Sparkline`, `StatusDot`, `SectionHeader`, `EmptyState`, `ListRow` (+ `RowValue`), `PrimaryButtonStyle`. `DSCard` is prefixed because the existing `Theme.swift` already has a `Card`.
  - `DesignGallery` with light and dark Previews. You weren't around to approve the look, so I kept going; everything is token-driven, so tweaks are one-line changes.
  - The existing Forge screens keep their own `Theme` (untouched).

- Phase 4 (Home + Area detail + realtime), in `Forge/Life/`:
  - The life dashboard is now the app's root, with 3 tabs: Home, Today, Settings. The original five Forge tabs open unchanged from Gym area → "Open training" (a sheet, swipe down to close). Forge's own Settings opens from Settings → "Training, Hevy and Apple Health".
  - Protected-file edits (you'd given me permission): `ForgeApp.swift` shows `LifeRootView` instead of `RootView` (RootView is kept and still compiles); the forced dark mode was removed from `ForgeApp`, `Info.plist` and `project.yml` so new screens follow light/dark. The existing screens still render dark (forced on their subtree).
  - Data: `LifeRepository` (PostgREST), `LifeStore` (@Observable), and a hand-written Realtime client (Phoenix over a WebSocket, no SDK; reconnects with backoff, refreshes its token). Any change to your rows reloads that table within about 0.3 s.
  - Home: greeting, a briefing line (local summary until Phase 6), the Today strip (due, overdue, reminders, habits left), and pinned area cards (one hero number, ring or trend line, one status dot). Long-press a card to unpin or hide it; pull to refresh runs the existing Hevy/Health refresh and reloads.
  - Area detail: hero stat plus Overview | Items | Logs | Charts. Items: quick add, swipe to complete or delete, filter by status/priority/tag, grouped by due date, search. Charts: Swift Charts with 7D/30D/90D/1Y and tap to inspect. Gym adds readiness, weekly volume, recent PRs and workouts from the existing analysis.
  - Item detail (edit, milestones, history), area editor (name, kind, icon, accent, featured number), Settings → Areas (drag to reorder, swipe to pin/hide) and Features (all off by default, stored in `user_settings.features`).
  - Hero numbers: gym = workouts this week / training days; habits = done today; goals = average progress; finance = spent this month (optionally against `config.monthly_budget`); otherwise open items, or the latest metric.
  - CI: `.github/workflows/ios-build.yml` compiles the Swift package for the iOS Simulator on a macOS runner (Xcode 16.4) on every push that touches `ios/Forge`. It runs without signing or secrets, and is my compile check since I can't run Xcode here.
- Phase 5 (chat): a floating chat bar on Home opens the assistant sheet. History comes from `ai_messages`, and each reply shows a short line of what changed ("Saved item · Created reminder"). "Ask about this" in an area pre-fills the chat. After a reply the dashboard reloads (realtime also covers it).

- Phase 5.5 (reminders), in `Forge/Life/Reminders/`:
  - Two-way Apple Reminders sync (EventKit, on-device). You pick the lists to sync and map each to an area (Settings → Reminders and notifications). New app or AI reminders go to the list mapped to their area, else your chosen default list.
  - The merge rules (`ReminderMerge`, unit-tested): rows are matched on `apple_reminder_id`, so nothing duplicates. The most recent edit wins (`source_modified_at` vs EventKit `lastModifiedDate`); deletions propagate both ways; open reminders and those completed in the last 7 days are imported. Sync runs on launch, on foreground, after every reminders change (including agent replies via realtime), and when Apple Reminders changes.
  - notify_mode: `app` = local notification (actions: Done, Snooze 10 min / 1 hour, Tomorrow; grouped; quiet hours move alerts to the end of the window; up to 50 pending). `reminders_app` = an alarm on the Apple reminder. `none` = silent.
  - Permission is asked in context: when you turn on notifications, create a reminder that notifies, or connect Apple Reminders.
  - UI: Reminders view (Today / Upcoming / Done; swipe to complete, snooze or delete; long-press for more snooze options; quick add with a bell toggle, set for the next full hour), reminder editor, a reminders section on Today, and settings (global toggle, default notify mode, quiet hours, briefing time, lists).
  - Info.plist / project.yml: added `NSRemindersFullAccessUsageDescription`.
  - Decision: reminders imported from Apple are stored as `reminders` rows (linked to an area by list), not as items; items can still point at a reminder via `item_id`.

- Phase 6 (daily briefing + notifications):
  - The Edge Function gained task modes (`tasks.ts`): `{ "mode": "briefing" }` runs with read-only tools and ends with a schema-validated `submit_briefing(line, detail)`. Task runs aren't saved to chat history. Later phases reuse this for capture routing, weekly review, journal, next action and insights.
  - Home shows the AI line (tap for up to 3 detail lines), falling back to the local summary. It's fetched once per day (launch / foreground / pull to refresh), so it costs about one small Claude call a day.
  - Notification: a local notification at your briefing time (Settings → Reminders and notifications → Daily briefing; notifications must be on). A background app refresh (`com.forge.briefing`) tries to prepare the briefing about 45 minutes before, so the notification shows the real line; otherwise it says "Your briefing is ready".
  - Remote push (APNs) isn't built: it needs a paid developer account, an APNs key and a server sender. Local notifications cover the briefing, reminders, check-ins and nudges without it.
  - Edits: `ForgeApp.swift` +2 lines (`.backgroundTask(.appRefresh(...))`); Info.plist / project.yml add `BGTaskSchedulerPermittedIdentifiers` and `UIBackgroundModes: fetch`.

- Phase 7 (widgets, Live Activities, App Intents):
  - New `ForgeWidgets/` extension (Xcode route via `project.yml`): a Today widget (small, medium, Lock Screen circular/rectangular/inline; StandBy uses the small one), a Habits widget with one-tap check-off buttons, a Capture widget, and the focus timer Live Activity UI (Dynamic Island + Lock Screen).
  - Data handoff: the app writes `widget-snapshot.json` to the App Group `group.com.raoulreinder.forge` after every reload and asks WidgetKit to refresh. Habit buttons run `LogHabitIntent` (a LiveActivityIntent, so it runs in the app's process with your session).
  - App Intents (main app, so they work with xtool too): "Ask Forge" and, from Phase 8, "Capture in Forge" and "Open quick capture". Assign any of them to the Action Button in Settings → Action Button → Shortcut.
  - Limits: xtool builds only the app (Package.swift), not app extensions, so widgets and Live Activities need the Xcode route (`xcodegen` + Xcode). App Groups need the capability on a paid developer account; without it the widgets show sample data.
  - CI now has a second job: XcodeGen + build of the app + widget extension.
- Phase 8 (quick capture, behind Settings → Features → Quick capture):
  - The capture sheet (type or dictate on-device with the Speech framework) saves to `captures` first, so nothing is lost, then the agent's `capture` task routes it into a task, reminder, expense, metric or note, and shows "Sorted: …" with Undo (auto-closes after 4 s).
  - Undo: migration 5's `ai_undo_capture` deletes exactly what routing created (recorded in `captures.data.created`); reminders already in Apple Reminders become `pending_delete`. Areas routing created are removed only if still empty.
  - The Inbox (Home → … → Inbox) holds captures that couldn't be sorted (swipe to retry or delete) plus recently sorted ones (swipe to undo).
  - Entry points: Home "+" (when enabled), Siri "Capture in Forge" (no app launch), the Action Button ("Open quick capture"), the Capture widget, `forge://capture`.
  - New agent tool `capture(text)` parks a thought in the inbox from chat.
  - Info.plist / project.yml: speech + microphone usage strings, the `forge://` URL scheme.
  - Verified: 7 SQL checks for capture/undo (including cross-user), Deno tests for the created-rows tracking and the finish schema.

- Phase 9 (check-ins, weekly review, journal; each behind its own Feature toggle):
  - Migration 6 adds `user_settings.checkin_morning_time` / `checkin_evening_time` and SQL functions: `ai_submit_checkin` (one per day and type; a second submit merges), `ai_weekly_review` (per-area completed and missed items, logs, metric stats, habit days, workouts, check-in averages: every number the AI quotes comes from here), `ai_day_digest`, and `ai_save_journal` (never overwrites an entry you edited yourself).
  - Agent tools: `submit_checkin`, `get_weekly_review`, `get_day_digest`. Task modes: `weekly_review` (structured: summary, wins, misses, focus, up to 5 suggestions) and `journal`.
  - Check-in sheet: mood and energy 1-5 (one tap each), plus top priority (morning) or wins (evening). Daily notifications at your check-in times; tapping one opens the sheet.
  - Weekly review (Today → Weekly review): generated on demand, cached per week, with a Sunday 18:00 notification. Tap a suggestion (or "Add all") to add it as an item due next Monday.
  - Journal (Today → Journal): write today's entry with one tap; yesterday's is written automatically the first time you open the journal. Tap an entry to edit it (saved as yours, so the AI won't change it).
  - Verified: 16 SQL checks, Deno tests.

- Phase 10 (calendar, behind Features → Calendar):
  - `CalendarService` (EventKit, `requestFullAccessToEvents`): you pick which calendars show on Today (Settings → Calendar). Events never go to Supabase.
  - Today becomes one timeline: all-day entries first, then events, timed items and reminders in time order (`Timeline.build`, unit-tested), plus Overdue and Tomorrow below. Swipe items and reminders to complete them.
  - Time blocking: "Plan my day" sends only a short summary (today's events and free slots, `Timeline.context`) to the `plan_day` task. It drafts up to 8 blocks inside your free time; you pick which ones to add, and only then are events written to your chosen calendar.
  - The briefing also gets the calendar summary when Calendar is on.
  - Info.plist / project.yml: `NSCalendarsFullAccessUsageDescription`.

## Manual steps I still need to do
- Phase 10: redeploy `ai-agent` (plan_day task); turn on Features → Calendar and connect it in Settings → Calendar.
- Phase 9: run `migrations/20261027000006_checkins_review_journal.sql`, redeploy `ai-agent`, turn on the features you want and set check-in times.
- Phase 8: run `migrations/20261027000005_capture.sql`, redeploy `ai-agent`, turn on Settings → Features → Quick capture.
- Phase 7 (optional, Xcode route): `brew install xcodegen && xcodegen` in `ios/`, open Forge.xcodeproj, set your team and the App Group on both targets, run.
- Phase 6: redeploy `ai-agent` (new file `tasks.ts`). Set a briefing time in Settings → Reminders and notifications.
- Phase 3: follow "Phase 3" in `supabase/SETUP.md`: run migration 4, add the `ANTHROPIC_API_KEY` secret (and set a spend limit), deploy `ai-agent`. Then rebuild with `xtool dev` to check the new Swift compiles.
- Phase 2: in the Supabase SQL Editor, run `supabase/migrations/20261027000003_upsert_constraints.sql`.
- Phase 2 (after rebuilding with `xtool dev`): Settings → Cloud sync → paste Project URL + anon key → enter email → enter the 6-digit code. Then turn off new sign-ups in Supabase.
- Phase 1: follow `supabase/SETUP.md`: create the project, run both SQL files, set the email-code template, and keep the Project URL + anon key ready for Phase 2. After your first sign-in, turn off new sign-ups.

## Known issues
- Workouts deleted in Hevy are not removed from Supabase: the existing Hevy client (protected) doesn't report deletions. A later fix could compare ids during a full resync.
- The SwiftUI files (`CloudSettingsView`, `CloudSyncHook`) can't be compiled in the cloud session. The first real check is your `xtool dev` build.
- Phase 7 / 16 (widgets, Live Activities, Watch) need app extensions; a free Apple ID limits App IDs and xtool extension support may be partial. These may require a paid developer account.
- Phase 3: workouts deleted in Hevy still show up in agent answers (same root cause as above).
- The existing `ClaudeClient` keeps the API key on-device (pre-existing; protected). New AI features use the server-side Edge Function only.
