-- Phase 1: core + extension tables for the life dashboard.
--
-- Conventions
-- - Every table has user_id (defaults to the signed-in user), created_at, updated_at.
-- - Row Level Security: a user can only see and write their own rows.
-- - Enumerations are text + CHECK constraints (easy to extend later without enum migrations).
-- - Child rows reference parents with composite (id, user_id) foreign keys, so a row can never
--   point at another user's area/item even if the uuid is known.
-- - Flexible data lives in jsonb (`data`, `config`) so the AI can track new things without schema changes.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Settings (one row per user): default notify mode, quiet hours, briefing time, feature toggles.
-- ---------------------------------------------------------------------------

create table public.user_settings (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  default_notify_mode text not null default 'app' check (default_notify_mode in ('app', 'reminders_app', 'none')),
  notifications_enabled boolean not null default false,
  quiet_hours_start time,
  quiet_hours_end time,
  briefing_time time,
  timezone text not null default 'UTC',
  features jsonb not null default '{}',      -- e.g. {"checkins": true, "money": false}
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Core tables
-- ---------------------------------------------------------------------------

create table public.areas (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  icon text,                                  -- SF Symbol name
  color text,                                 -- hex accent, e.g. "#5B8CFF"
  kind text not null default 'custom' check (kind in ('gym', 'tasks', 'goals', 'habits', 'finance', 'dev', 'custom')),
  config jsonb not null default '{}',
  sort_order integer not null default 0,
  pinned boolean not null default false,
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id)
);
-- One area per name per user, so create_area is idempotent.
create unique index areas_user_name_key on public.areas (user_id, lower(name));

create table public.items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  area_id uuid not null,
  parent_id uuid,                             -- goal -> milestones
  title text not null check (length(trim(title)) > 0),
  status text not null default 'not_started' check (status in ('not_started', 'in_progress', 'done', 'blocked')),
  progress smallint not null default 0 check (progress between 0 and 100),
  priority smallint not null default 0 check (priority between 0 and 3),  -- 0 none, 1 low, 2 medium, 3 high
  due_date timestamptz,
  recurrence text,                            -- RFC 5545 RRULE, e.g. "FREQ=DAILY"
  tags text[] not null default '{}',
  data jsonb not null default '{}',           -- e.g. {"shared": true} for shopping lists
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (area_id, user_id) references public.areas (id, user_id) on delete cascade,
  foreign key (parent_id, user_id) references public.items (id, user_id) on delete set null (parent_id)
);
create index items_user_area_idx on public.items (user_id, area_id);
create index items_user_due_idx on public.items (user_id, due_date) where status <> 'done';
create index items_parent_idx on public.items (parent_id) where parent_id is not null;

create table public.logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  area_id uuid not null,
  item_id uuid,                               -- habit completions, focus sessions, etc.
  note text,
  data jsonb not null default '{}',           -- e.g. {"minutes": 25} for focus sessions
  logged_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (area_id, user_id) references public.areas (id, user_id) on delete cascade,
  foreign key (item_id, user_id) references public.items (id, user_id) on delete set null (item_id)
);
create index logs_user_area_time_idx on public.logs (user_id, area_id, logged_at desc);
create index logs_item_time_idx on public.logs (item_id, logged_at desc) where item_id is not null;

create table public.metrics (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  area_id uuid not null,
  name text not null,                         -- "bodyweight", "sleep_hours", "expense", ...
  value double precision not null,
  unit text,
  recorded_at timestamptz not null default now(),
  data jsonb not null default '{}',           -- e.g. {"category": "food"} for expenses
  source text not null default 'manual',      -- manual | ai | healthkit | hevy | ...
  external_id text,                           -- stable id from an integration, e.g. "hrv:2026-10-27"
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (area_id, user_id) references public.areas (id, user_id) on delete cascade
);
create index metrics_series_idx on public.metrics (user_id, area_id, name, recorded_at desc);
-- Integrations upsert on this, so re-syncing never duplicates.
create unique index metrics_external_key on public.metrics (user_id, source, external_id) where external_id is not null;

create table public.integrations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  provider text not null,                     -- hevy | healthkit | reminders | calendar | ...
  status text not null default 'disconnected' check (status in ('connected', 'disconnected', 'syncing', 'error')),
  last_synced_at timestamptz,
  config jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, provider),
  -- Guard rail: never store raw secrets here (they live in the Keychain or Supabase secrets).
  constraint integrations_no_secrets check (
    not (config ?| array['api_key', 'apiKey', 'key', 'token', 'access_token', 'refresh_token', 'secret', 'password'])
  )
);

create table public.ai_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  role text not null check (role in ('user', 'assistant', 'tool', 'system')),
  content text,
  tool_calls jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index ai_messages_user_time_idx on public.ai_messages (user_id, created_at desc);

-- Hevy workouts (one row per workout) + sets (one row per set).
create table public.workouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  area_id uuid,                               -- the gym area
  hevy_id text not null,
  title text not null,
  description text,
  started_at timestamptz not null,
  ended_at timestamptz,
  hevy_updated_at timestamptz,                -- for incremental sync
  data jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, hevy_id),                  -- upsert target
  foreign key (area_id, user_id) references public.areas (id, user_id) on delete set null (area_id)
);
create index workouts_user_time_idx on public.workouts (user_id, started_at desc);

create table public.workout_sets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  workout_id uuid not null,
  exercise_index integer not null,
  exercise_title text not null,
  exercise_template_id text,
  superset_id integer,
  set_index integer not null,
  set_type text,                              -- warmup | normal | failure | dropset
  weight_kg double precision,
  reps integer,
  distance_meters double precision,
  duration_seconds double precision,
  rpe double precision,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workout_id, exercise_index, set_index),  -- upsert target
  foreign key (workout_id, user_id) references public.workouts (id, user_id) on delete cascade
);
create index workout_sets_exercise_idx on public.workout_sets (user_id, exercise_title);

create table public.reminders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  item_id uuid,
  area_id uuid,
  title text not null check (length(trim(title)) > 0),
  notes text,
  remind_at timestamptz,
  repeat_rule text,                           -- RRULE
  notify_mode text not null default 'app' check (notify_mode in ('app', 'reminders_app', 'none')),
  apple_reminder_id text,                     -- EKReminder.calendarItemIdentifier
  sync_status text not null default 'pending_push' check (sync_status in ('synced', 'pending_push', 'pending_delete', 'conflict', 'error')),
  completed_at timestamptz,
  source_modified_at timestamptz,             -- last edit time on either side; most recent wins
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (item_id, user_id) references public.items (id, user_id) on delete set null (item_id),
  foreign key (area_id, user_id) references public.areas (id, user_id) on delete set null (area_id)
);
create unique index reminders_apple_id_key on public.reminders (user_id, apple_reminder_id) where apple_reminder_id is not null;
create index reminders_user_time_idx on public.reminders (user_id, remind_at) where completed_at is null;

-- ---------------------------------------------------------------------------
-- Extension tables
-- ---------------------------------------------------------------------------

create table public.checkins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  type text not null check (type in ('morning', 'evening')),
  mood smallint check (mood between 1 and 5),
  energy smallint check (energy between 1 and 5),
  wins text,
  notes text,
  date date not null default current_date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, date, type)
);

create table public.captures (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  raw_text text not null,
  source text not null default 'text' check (source in ('text', 'voice', 'siri', 'widget')),
  routed_area_id uuid,
  routed_item_id uuid,
  status text not null default 'inbox' check (status in ('inbox', 'sorted')),
  data jsonb not null default '{}',           -- what the router created, for undo
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (routed_area_id, user_id) references public.areas (id, user_id) on delete set null (routed_area_id),
  foreign key (routed_item_id, user_id) references public.items (id, user_id) on delete set null (routed_item_id)
);
create index captures_inbox_idx on public.captures (user_id, created_at desc) where status = 'inbox';

create table public.people (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null,
  birthday date,
  last_contacted timestamptz,
  notes text,
  gift_ideas jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text not null,
  category text,
  notes text,
  location_note text,                         -- "top drawer, blue folder"
  expires_at date,
  file_path text,                             -- path in the private "documents" bucket
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null,
  amount numeric(12, 2) not null check (amount >= 0),
  currency char(3) not null default 'USD',
  billing_cycle text not null default 'monthly' check (billing_cycle in ('weekly', 'monthly', 'quarterly', 'yearly')),
  renews_on date,
  area_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (area_id, user_id) references public.areas (id, user_id) on delete set null (area_id)
);

create table public.body_measurements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  type text not null,                         -- waist, chest, arm, ...
  value double precision not null,
  unit text not null,
  recorded_at timestamptz not null default now(),
  photo_path text,                            -- path in the private "photos" bucket
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index body_measurements_series_idx on public.body_measurements (user_id, type, recorded_at desc);

create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  date date not null default current_date,
  content text not null default '',
  source text not null default 'manual' check (source in ('ai', 'manual')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, date)
);

create table public.insights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  area_ids uuid[] not null default '{}',
  text text not null,
  kind text not null check (kind in ('correlation', 'nudge', 'trend')),
  sample_size integer,                        -- how many data points back this insight
  dismissed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index insights_active_idx on public.insights (user_id, created_at desc) where not dismissed;

-- ---------------------------------------------------------------------------
-- updated_at triggers + Row Level Security for every table
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'user_settings', 'areas', 'items', 'logs', 'metrics', 'integrations', 'ai_messages',
    'workouts', 'workout_sets', 'reminders', 'checkins', 'captures', 'people', 'documents',
    'subscriptions', 'body_measurements', 'journal_entries', 'insights'
  ]
  loop
    execute format('create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()', t);
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "own rows" on public.%I for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))',
      t
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- New users get a settings row automatically.
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.user_settings (user_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Realtime: tables the app subscribes to.
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      public.areas, public.items, public.logs, public.metrics, public.reminders,
      public.ai_messages, public.captures, public.checkins, public.insights;
  end if;
end;
$$;
