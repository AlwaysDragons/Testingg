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
