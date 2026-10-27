# CLAUDE.md: AI-Run Life Dashboard (SwiftUI iOS)

Read `PROGRESS.md` at the start of every session.

## PROTECT EXISTING CODE (highest priority rule)
- The app already tracks Apple Health (HealthKit) and syncs Hevy via its API. That code works. Do NOT delete, rewrite, rename, or move it.
- Changes are ADDITIVE ONLY. To fit existing code into the new Integration protocol, write thin adapter/wrapper types around it instead of refactoring its internals.
- If you believe an existing file must change, stop and tell me what and why before touching it. Keep edits minimal.
- Before each phase: make sure git is clean, work on a branch (e.g. `phase-N-name`), and commit when done so I can roll back.
- Never remove existing features, screens, models, or permissions to make the new architecture cleaner.

## PROJECT OVERVIEW
A SwiftUI iOS app that is an AI-run dashboard for my whole life (gym, to-dos, goals, app dev, money, habits, health, anything). It started as a Hevy-only gym app. Gym is now ONE module, not the core. I open this app every day to make life easier.

On first session: read the codebase and summarize how the Hevy and HealthKit integrations work (auth, models, networking, storage). List the files you will NOT modify. Ask up to 3 questions if needed. Do not write code until I approve a plan.

## CORE IDEA
Everything is an "area" of my life containing generic "items", "logs", and "metrics". Integrations (Hevy, HealthKit, Reminders, Calendar, others later) feed data into those same tables. The AI can create new areas on the fly ("start tracking my sleep") without schema changes.

## ARCHITECTURE
- Supabase (Postgres + Auth + Realtime + Storage) is the single source of truth.
- A Supabase Edge Function (`ai-agent`) takes my message, calls an LLM with tool calling, validates args against a schema, and writes to the DB. API keys stay server-side, never in the app.
- iOS (and a future web app) reads via realtime subscriptions and sends messages to the Edge Function.
- MVVM + repository layer. An `Integration` protocol so new providers can be added without touching core code.
- Anything that touches EventKit (Reminders, Calendar) runs on-device only. The Edge Function returns the result and the app writes it locally.
- Secrets live in `.env` / Supabase secrets, are gitignored, and are never hardcoded. Photo and document storage buckets are PRIVATE (signed URLs only).

## CORE TABLES
All tables: RLS so users only see their own rows; include `user_id`, `created_at`, `updated_at`.
- `areas`: id, name, icon, color, kind (gym | tasks | goals | habits | finance | dev | custom), config (jsonb), sort_order, pinned, hidden
- `items`: id, area_id, title, status (not_started | in_progress | done | blocked), progress 0-100, priority, due_date, recurrence, tags[], data (jsonb)
- `logs`: id, area_id, item_id nullable, note, logged_at
- `metrics`: id, area_id, name, value, unit, recorded_at (time series: bodyweight, savings, sleep hours, expenses, etc.)
- `integrations`: id, provider (hevy | healthkit | reminders | calendar | ...), status, last_synced_at, config (jsonb, no raw secrets)
- `ai_messages`: id, role, content, tool_calls (jsonb)
- `workouts` + `workout_sets`: Hevy data, `hevy_id` unique, linked to the gym area. Upsert on `hevy_id`.
- `reminders`: id, item_id nullable, area_id, title, notes, remind_at, repeat_rule, notify_mode, apple_reminder_id, sync_status

## EXTENSION TABLES (for everyday features)
- `checkins`: id, type (morning | evening), mood, energy, wins, notes, date
- `captures`: id, raw_text, source (text | voice | siri | widget), routed_to (area_id/item_id nullable), status (inbox | sorted)
- `people`: id, name, birthday, last_contacted, notes, gift_ideas (jsonb)
- `documents`: id, title, category, notes, location_note, expires_at, file_path nullable
- `subscriptions`: id, name, amount, currency, billing_cycle, renews_on, area_id
- `body_measurements`: id, type, value, unit, recorded_at, photo_path nullable
- `journal_entries`: id, date, content, source (ai | manual)
- `insights`: id, area_ids[], text, kind (correlation | nudge | trend), created_at, dismissed

Reuse generic tables where possible: habits = items with recurrence + logs for completions (compute streaks from logs). Expenses = metrics (name "expense", category in data jsonb). Meals, water, supplements = logs + metrics. Shopping lists = items with a shared flag.

## HEVY SYNC
- Keep existing Hevy code. Wrap it as `HevyIntegration` (adapter) that writes into Supabase.
- Initial backfill, then incremental sync by date. Upsert on `hevy_id` so there are no duplicates.
- Run on app launch and pull-to-refresh.
- Hevy API key stays in Keychain (or encrypted server-side if sync moves to the Edge Function).

## APPLE HEALTH
- Keep the current HealthKit logic as-is. Expose it as a `HealthKitIntegration` adapter that writes into the generic `metrics` table (steps, sleep, weight, HRV, etc.) without changing how the existing code reads data.

## REMINDERS (Apple Reminders + in-app)
- Use EventKit (`EKEventStore`, `EKReminder`). Request access with `requestFullAccessToReminders()` (iOS 17+) and add `NSRemindersFullAccessUsageDescription` to Info.plist.
- Two-way sync between Apple Reminders and my dashboard:
  - Import reminders from chosen lists into items (store `apple_reminder_id` = `calendarItemIdentifier`).
  - Reminders created in-app or via AI get written to Apple Reminders.
  - Completion and edits sync both ways. Conflict rule: most recent modification wins.
  - I choose which Reminders lists sync and map each list to an area.
- Each reminder has a `notify_mode`:
  - `app`: local notification from my app (`UNUserNotificationCenter`)
  - `reminders_app`: alarm set on the EKReminder, so the Reminders app notifies me
  - `none`: silent; appears in the dashboard and Today strip only
- Notifications: ask permission in context (not on first launch). Actionable notifications (Done, Snooze 10m / 1h / Tomorrow). Reschedule local notifications on launch and after sync. Settings screen: global toggle, default notify mode, quiet hours, daily briefing time.
- Never create duplicates: dedupe on `apple_reminder_id` and stable ids.

## AI TOOLS (schema-validated before any write)
Core:
- `create_area(name, kind, icon)`
- `upsert_item(area, id, title, status, progress, priority, due, tags, data)`
- `complete_item(id)` / `delete_item(id)`
- `log_entry(area, note)`
- `record_metric(area, name, value, unit)`
- `query_area(area, date_range, filters)`: items, logs, metrics, and Hevy data when area is gym
- `get_dashboard_summary(area?)`
- `get_daily_briefing()`: what's due, what's behind, what I did yesterday

Reminders:
- `create_reminder(title, remind_at, repeat, area, notify_mode, notes)`
- `update_reminder(id, ...)` / `complete_reminder(id)` / `delete_reminder(id)`
- `list_reminders(area?, date_range?)`

Everyday:
- `capture(text, source)`: routes and returns where it landed
- `submit_checkin(type, mood, energy, wins, notes)`
- `get_weekly_review(week)`
- `suggest_next_action()`
- `log_habit(item_id)` / `get_streaks(area?)`
- `start_focus_session(area, minutes)` / `end_focus_session()`
- `log_expense(amount, category, note)` / `get_budget_status(month)`
- `log_measurement(type, value, unit)`
- `add_person` / `log_contact(person)` / `list_upcoming_birthdays()`
- `save_document(title, category, location_note, expires_at)`
- `search_all(query)`: unified results across all tables
- `get_insights()` / `dismiss_insight(id)`

Rules:
- Reuse stable ids so items update instead of duplicating.
- Never invent numbers. Use null for unknowns.
- Ask when ambiguous. If I say "remind me" without a time, ask.
- If I don't specify notify mode, use my default.
- Confirm what was done in one short line.
- If I mention something that fits no area, propose creating one.
- Anything that writes to Calendar or Reminders is returned to the app and written on-device.

## DESIGN PRINCIPLES (every screen)
- Modern, sleek, minimalist. Visual references: Apple Fitness, Things 3, Linear, Oura. Not clunky, not cluttered.
- Glanceable first: Home must answer "how am I doing?" in under 3 seconds. Detail lives one tap deeper.
- Progressive disclosure: Home (glance) -> Area (overview) -> Item/metric (full detail, history, edit).
- One primary idea per card. Max ~3 data points visible per card.
- Large rounded corners (20pt), subtle materials, no heavy borders or shadows.
- Typography: SF Pro, rounded numerals for big stats, clear hierarchy (one large number, one label, one small secondary line).
- Color: neutral base, ONE accent per area (from `areas.color`). Color only signals meaning (progress, status, overdue). Full light + dark mode.
- Motion: subtle springs, matched-geometry transitions from card to detail, haptics on completion. Nothing flashy.
- Respect Dynamic Type, VoiceOver, and safe areas.

## MINIMAL DESIGN ENFORCEMENT (applies to EVERY screen and feature, overrides feature enthusiasm)
Core rule: with 50+ features, the app must still feel like it has 5. Features exist, but stay out of sight until needed.

Home screen limits:
- Max 1 briefing line, 1 Today strip, and 4-6 area cards visible without scrolling. Everything else is one tap deeper.
- No feature gets a permanent spot on Home by default. Only pinned areas appear. New features start hidden and I turn them on in Settings.
- One hero number per card. No stacked badges, one status indicator max, no captions under captions.
- No dashboards inside dashboards: no tab bars inside cards, no nested scrolls, max 3 tabs in the main tab bar.

Visual style:
- Neutral background (near-white / near-black), cards one step off the background. Use spacing and type hierarchy, not borders, dividers, or shadows.
- Palette: neutrals + one accent per area, used sparingly (rings, progress, status). No gradients, no multi-color charts, no decorative icons.
- Type: SF Pro, 3 sizes per screen max (large number, body, caption). Sentence case, no ALL CAPS labels.
- 8pt grid, generous padding (16-24pt), consistent 20pt corner radius. Whitespace is a feature; don't fill it.
- Icons: SF Symbols, one weight, monochrome. No emoji in UI chrome.
- Charts: single series by default, faint or no gridlines, no legends unless needed, direct value labels on tap.

Interaction:
- Progressive disclosure everywhere. Never show detail on the glance layer.
- One primary action per screen. Secondary actions go in menus, swipe actions, or long-press.
- Prefer gestures and context menus to visible buttons. No row with more than one visible control.
- Sheets for quick flows (capture, check-in), full screens for browsing. Dismiss by swipe.
- Motion: short springs only. No looping, bouncing, or attention-seeking animation.

Copy and notifications:
- Short, calm, plain language. No exclamation marks, no emoji, no gamified spam.
- In-app AI replies: max 2 sentences unless I ask for detail.
- Notifications: grouped, rate-limited, off by default for anything non-essential, respect quiet hours.

Self-check before any screen is done:
- Can I remove anything and still understand this screen? If yes, remove it.
- Does it pass the 3-second glance test?
- Is there more than one competing focal point? If yes, simplify.
- Show me the SwiftUI Preview in light AND dark mode and wait for my OK on the look before wiring data.

Design system first:
- Phase 3.5 produces tokens (colors, spacing, radius, type scale) and components (Card, StatView, ProgressRing, SectionHeader, EmptyState, ListRow). Views may ONLY use these. No hardcoded colors, fonts, or spacing in feature code.

## HOME SCREEN (glance view)
- Top: greeting + AI daily briefing in 1-2 lines (tap to expand).
- Today strip: what's due, overdue count, reminders due, habits left.
- Stack/grid of area cards: icon, name, one hero stat (e.g. "4/5 workouts"), a slim progress ring or sparkline, a status dot.
- Cards reorderable, pinnable, hideable.
- Floating compact chat bar at the bottom that expands into a full AI chat sheet.
- Pull to refresh syncs integrations.

## AREA DETAIL (deep view)
- Header with hero stat and a segmented control: Overview | Items | Logs | Charts.
- Swift Charts with range picker (7D / 30D / 90D / 1Y), tap to inspect values.
- Items: swipe to complete/delete, filter by status/tag/priority, grouped by due date.
- Gym area adds: recent workouts, PRs, weekly volume, per-exercise progression.
- Area reminders shown here. Timeline of logs and AI summaries, search, and an "Ask AI about this" button that pre-fills chat with context.

## REMINDERS UI
- Reminders view grouped Today / Upcoming / Done, swipe to complete or snooze, quick-add with a notify toggle (bell / bell-slash).

## EVERYDAY USE FEATURES
All additive only and subject to PROTECT EXISTING CODE and MINIMAL DESIGN ENFORCEMENT. Every feature needs a graceful empty state and a Settings toggle. Daily flows (capture, check-in, habit tap) take under 10 seconds and no more than 3 taps.

### Tier 1: build first (daily-open drivers)
1. **Quick capture:** one tap, text or voice (Speech framework), also via Action Button, Siri/App Intents, and a widget. Lands in the captures inbox, then the AI routes it to the right area as a task, reminder, expense, or note. Show "Sorted into X" with undo.
2. **Morning + evening check-in:** 2-3 tap-friendly questions (mood, energy, top priority / wins). Triggered by a notification at my set times. Logged to `checkins`; the AI uses them in summaries.
3. **Weekly review:** AI summarizes wins, misses, streaks, and metrics per area, suggests next week's focus. Sunday notification. One tap to accept suggestions into items.
4. **Calendar integration** (EventKit, `requestFullAccessToEvents`): Today is one unified timeline of events, tasks, and reminders. I choose which calendars show.

### Tier 2: daily quality of life
- "What should I do now?": AI reads calendar gaps, latest check-in energy, due/overdue items; suggests one next action plus 2 alternates.
- Habit streaks: one-tap check-off from widgets and Home, configurable grace/skip rule.
- Focus timer: Live Activity, logs time to the chosen area, shows total focus time per area.
- Time blocking: AI drafts my day around calendar events and priorities. I approve before anything is written to Calendar.
- Goals with milestones: goal = parent item, milestones = child items, progress rolls up automatically.
- Daily journal auto-written from the day's logs, check-ins, workouts, and completed items. Editable, saved to `journal_entries`.

### Tier 3: health and gym (build on existing HealthKit + Hevy code, don't modify it)
- Auto PR detection from Hevy with a subtle celebration (haptic + card).
- Recovery score (0-100 ring) from sleep, HRV, resting HR, and recent Hevy volume.
- "Skip or push today?" suggestion on the gym card.
- Water, meals, supplements quick-log with targets (protein, calories, water) in config.
- Body measurements + progress photo timeline (private Supabase Storage with signed URLs, or on-device only if I choose).

### Tier 4: money
- Chat expense logging ("spent 12 on lunch") with auto-categorization. Ask if ambiguous.
- Budget rings per category, monthly view.
- Subscription tracker with renewal reminders (uses the reminders system and notify_mode).
- Savings goals with progress bars.

### Tier 5: smart AI
- Cross-area insights (e.g. sleep vs gym days). Only surface when there is enough data, state the sample size, never invent correlations.
- Proactive nudges ("no weight logged in 5 days"): rate-limited, configurable, respect quiet hours.
- Natural-language search across everything ("when did I last deadlift 200?").

### Tier 6: life admin
- People: birthdays (auto-reminders), last contacted, gift ideas, "reach out" nudges.
- Shopping and grocery lists (shared flag).
- Documents and "where is it" notes with expiry reminders.
- Travel plans and reusable packing lists.

### Tier 7: phone-native
- Lock Screen widgets, home widgets, StandBy dashboard.
- Apple Watch companion (separate target, additive only): check-in, habit tap, quick capture, today view.
- Focus mode integration: different areas shown for Work vs Gym vs Personal.
- Face ID lock per area (finance, journal, photos) via `areas.config`.

## BUILD RULES
- Work one phase at a time (see PROGRESS.md). Plan first, then build. Stop after each phase and wait for my OK.
- Branch per phase, commit when done.
- Build with `xcodebuild` after changes and fix errors before reporting done.
- Reusable components only. No one-off styling.
- Show SwiftUI Previews (light + dark) for each screen before wiring data.
- Keep code minimal and commented.
- Update PROGRESS.md after each phase with what was done, decisions made, and manual steps I still owe.
- Flag every manual step for me (API keys, Supabase dashboard config, Info.plist permissions, capabilities).
- Never hardcode secrets. Never make storage buckets public.
