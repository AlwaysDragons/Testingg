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
- [ ] 1. Supabase schema + RLS (SQL + setup steps)
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
- Pending your answers (asked in Phase 0):
  1. Supabase project exists? Auth via email OTP (Sign in with Apple needs a paid developer account).
  2. Verification: `xcodebuild`/Previews can't run in the cloud session. Proposed: Linux type-check for non-UI code + an HTML mock for look approval + you run `xtool dev` and paste errors.
  3. Existing Forge screens break the new design rules. Proposed: keep them untouched, hosted inside the Gym area.

## Manual steps I still need to do
- (none yet; Phase 1 will add Supabase project creation + running the SQL)

## Known issues
- Phase 7 / 16 (widgets, Live Activities, Watch) need app extensions; a free Apple ID limits App IDs and xtool extension support may be partial. These may require a paid developer account.
- The existing `ClaudeClient` keeps the API key on-device (pre-existing; protected). New AI features use the server-side Edge Function only.
