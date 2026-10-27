# Supabase setup (Phase 1)

About 10 minutes, all in the browser. No CLI needed.

## 1. Create the project
1. Go to **supabase.com** → sign up → **New project**.
2. Name: `life-dashboard`. Pick the region closest to you. Set a strong **database password** and save it in your password manager.
3. Wait about 2 minutes for the project to start.

## 2. Run the SQL (in this order)
1. Left sidebar → **SQL Editor** → **New query**.
2. Paste all of `migrations/20261027000001_core_schema.sql` → **Run**. It should say "Success. No rows returned".
3. New query → paste `migrations/20261027000002_storage.sql` → **Run**.
4. Check: **Table Editor** lists 18 tables, each with an "RLS enabled" badge. **Storage** shows `photos` and `documents`, both marked **Private**.

## 3. Sign-in by email code
1. **Authentication → Sign In / Providers → Email**: enabled, with **Confirm email** on.
2. **Authentication → Email Templates → Magic Link**: replace the body with:
   ```
   <h2>Your sign-in code</h2>
   <p>{{ .Token }}</p>
   ```
   The app asks for this 6-digit code (no links needed).
3. After you sign in for the first time (Phase 2): **Authentication → Sign In / Providers → turn OFF "Allow new users to sign up"**. Then nobody else can create an account on your private backend.

## 4. Copy your keys (for Phase 2)
**Project Settings → API**:
- **Project URL**, e.g. `https://abcd1234.supabase.co`
- **anon / publishable key**: the app uses this. It's safe on-device because security rules protect every row.
- **service_role / secret key**: never put it in the app or in git. Only the Edge Function uses it (Phase 3), and Supabase injects it automatically.

Keep the URL and anon key handy. In Phase 2 they go into a gitignored `Support/Secrets.plist`.

## Notes
- The built-in email sender is rate-limited (a few emails per hour). That's fine for a single user.
- To start over: **Project Settings → General → Delete project**, then repeat.

# Phase 3: AI agent (Edge Function)

About 10 minutes.

## 1. Run the SQL
SQL Editor → New query → paste `migrations/20261027000004_ai_tools.sql` → **Run**. (Run `..._03_upsert_constraints.sql` first if you haven't yet.)

## 2. Anthropic API key
1. **console.anthropic.com** → API Keys → **Create key**. Also set a monthly spend limit under **Billing → Limits**.
2. Supabase: **Edge Functions → Secrets** → add `ANTHROPIC_API_KEY` = your key. Never put it in the app or in git.
3. Optional secrets: `AI_MODEL` (default `claude-sonnet-5-5`), `AI_EFFORT` (`low` | `medium` | `high`, default `medium`; lower = faster and cheaper).

## 3. Deploy the function
**Browser:** Edge Functions → **Deploy a new function → Via editor** → name it `ai-agent` (exactly). Create one file per `.ts` file in `functions/ai-agent/` (`index.ts`, `agent.ts`, `tools.ts`, `tasks.ts`; skip `agent_test.ts`) → **Deploy**. Leave **Verify JWT** on.

**Or CLI:** `supabase functions deploy ai-agent --project-ref <your-ref>` from the `ios/` folder.

## 4. Check it
Edge Functions → `ai-agent` → **Logs** should show it booted. The first real test is the chat in Phase 5 (it needs your signed-in session).

Notes:
- The function never uses the service_role key. It acts as you, so RLS protects every row.
- Every chat message and reply is saved in `ai_messages`.

# After later phases
Some phases change the function or add SQL. Each phase's PROGRESS.md entry says what to re-run. In general:
- New files in `migrations/` → run them in order in the SQL Editor.
- Changed `functions/ai-agent/*.ts` → redeploy `ai-agent` (same steps as above; paste the updated files).
