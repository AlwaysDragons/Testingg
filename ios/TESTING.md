# Test it and put it on your iPhone (Mac, about 20 minutes)

Run everything from Terminal on your Mac. Replace the `<...>` parts.

## 1. Get the code
```bash
git clone https://github.com/AlwaysDragons/Testingg.git && cd Testingg/ios
# or, in an existing clone:  git fetch && git checkout phase-17-polish && cd ios
git checkout phase-17-polish
```

## 2. Backend (Supabase CLI, one time)
```bash
brew install supabase/tap/supabase
supabase login
supabase link --project-ref <your-project-ref>      # the ref is in your project URL: https://<ref>.supabase.co
# If you already ran 01 and 02 by hand in the SQL Editor (Phase 1), mark them as done first:
supabase migration repair --status applied 20261027000001 20261027000002
supabase db push                                      # runs 03..12 (and any you haven't run)
supabase secrets set ANTHROPIC_API_KEY=<your-key>     # set a spend limit in the Anthropic Console too
supabase functions deploy ai-agent
```
New project? Do steps 1 and 3 of `supabase/SETUP.md` first (create the project, set the email-code template). `db push` then runs all migrations.

## 3. Build and install
Free Apple ID (app only, no widgets/Watch):
```bash
brew install xcodegen
xcodegen --spec project-phone.yml && open Forge.xcodeproj
```
Paid developer account (app + widgets + Live Activities + Watch):
```bash
xcodegen && open Forge.xcodeproj
```
In Xcode:
1. Settings → Accounts → add your Apple ID.
2. Forge target → Signing & Capabilities → pick your Team. If the bundle id is taken, change `com.yourname.forge` to e.g. `com.raoul.forge` (paid route: also the widgets and Watch targets and the App Group).
3. iPhone: Settings → Privacy & Security → Developer Mode → On. Plug it in, select it at the top of Xcode, press Run (⌘R).
4. First launch only: iPhone Settings → General → VPN & Device Management → trust your Apple ID.

To try it without the phone first: pick an iPhone simulator at the top of Xcode and press Run. HealthKit, Face ID and notifications are limited in the simulator.

## 4. First run checklist (5 minutes)
- Settings → Cloud sync: paste Project URL + anon key, enter your email, enter the 6-digit code.
- Settings → Features: turn on what you want.
- Home: pull to refresh. Areas and the Gym card should appear.
- Chat bar: "start tracking my sleep" → a Sleep area appears within a few seconds.
- "remind me to call mom tomorrow at 6pm" → appears under Reminders (and in Apple Reminders if you connected it).
- Capture (+): "spent 12 on lunch" → "Sorted into Money" with Undo.

If something breaks, send me the Xcode error (red line in the Issue navigator) or a screenshot, and the Supabase function log (Edge Functions → ai-agent → Logs).

## Run the checks without a phone
```bash
xcodebuild build -scheme Forge -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO   # same as CI
```
