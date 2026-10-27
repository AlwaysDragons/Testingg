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
- [ ] 2. Wrap Hevy and HealthKit as Integration adapters + sync into Supabase
- [ ] 3. Edge Function + tool calling
- [ ] 3.5. Design system + component library (tokens, Card, StatView, ProgressRing, SectionHeader, EmptyState, ListRow)
- [ ] 4. SwiftUI Home + Area detail + realtime
- [ ] 5. Chat wired to the agent
- [ ] 5.5. Reminders: EventKit two-way sync + local notifications + settings + AI reminder tools
- [ ] 6. Daily briefing + push notifications
- [ ] 7. Widgets, Live Activities, App Intents
- [ ] 8. Quick capture + inbox + routing + Siri/Action Button/widget entry
- [ ] 9. Check-ins + weekly review + daily journal
- [ ] 10. Calendar integration + unified Today timeline
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

## Manual steps I still need to do
- Phase 1: follow `supabase/SETUP.md`: create the project, run both SQL files, set the email-code template, and keep the Project URL + anon key ready for Phase 2. After your first sign-in, turn off new sign-ups.

## Known issues
- Phase 7 / 16 (widgets, Live Activities, Watch) need app extensions; a free Apple ID limits App IDs and xtool extension support may be partial. These may require a paid developer account.
- The existing `ClaudeClient` keeps the API key on-device (pre-existing; protected). New AI features use the server-side Edge Function only.
