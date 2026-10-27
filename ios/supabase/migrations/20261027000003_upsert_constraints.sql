-- Phase 2: PostgREST upserts (`on_conflict=...`) need plain unique constraints, not partial indexes.
-- Behavior is unchanged: NULLs never conflict with each other, so rows without an external id stay unrestricted.

drop index if exists public.metrics_external_key;
alter table public.metrics
  add constraint metrics_external_key unique (user_id, source, external_id);

drop index if exists public.reminders_apple_id_key;
alter table public.reminders
  add constraint reminders_apple_id_key unique (user_id, apple_reminder_id);
