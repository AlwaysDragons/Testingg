-- Phase 3: database side of the AI agent's tools.
--
-- Each AI tool maps to one `ai_*` function. The Edge Function validates arguments first, then calls
-- these through PostgREST RPC with the user's own JWT.
-- - security invoker: they run as the signed-in user, so Row Level Security still applies.
-- - Areas can be referenced by id or by name (case-insensitive).
-- - Writes reuse stable ids / titles so repeated requests update instead of duplicating.
-- - Errors are raised with a short machine-readable prefix (e.g. "area_not_found") that the AI sees.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Resolve an area by uuid or name. Raises if it does not exist.
create or replace function public.ai_area_id(p_area text)
returns uuid
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_area is null or length(trim(p_area)) = 0 then
    raise exception 'area_required';
  end if;
  select id into v_id
  from areas
  where id::text = trim(p_area) or lower(name) = lower(trim(p_area))
  limit 1;
  if v_id is null then
    raise exception 'area_not_found: %', p_area using hint = 'Use create_area first or pick an existing area.';
  end if;
  return v_id;
end;
$$;

-- The user's timezone (from user_settings), used to compute "today".
create or replace function public.ai_tz()
returns text
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce((select timezone from user_settings where user_id = auth.uid()), 'UTC');
$$;

-- ---------------------------------------------------------------------------
-- Core tools
-- ---------------------------------------------------------------------------

-- create_area: idempotent on name.
create or replace function public.ai_create_area(p_name text, p_kind text default 'custom', p_icon text default null, p_color text default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row areas;
  v_created boolean := false;
begin
  select * into v_row from areas where lower(name) = lower(trim(p_name));
  if v_row.id is null then
    insert into areas (name, kind, icon, color, sort_order)
    values (trim(p_name), coalesce(p_kind, 'custom'), p_icon, p_color,
            coalesce((select max(sort_order) + 1 from areas), 0))
    returning * into v_row;
    v_created := true;
  end if;
  return jsonb_build_object('action', case when v_created then 'created' else 'exists' end, 'area', to_jsonb(v_row));
end;
$$;

-- upsert_item: update by id, else by open item with the same title in the area, else insert.
-- Only keys present in p change; an explicit JSON null clears a nullable field.
create or replace function public.ai_upsert_item(p jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row items;
  v_area uuid;
  v_status text;
  v_action text;
begin
  if p ? 'area' and p->>'area' is not null then
    v_area := ai_area_id(p->>'area');
  end if;

  if p->>'id' is not null then
    select * into v_row from items where id = (p->>'id')::uuid;
    if v_row.id is null then
      raise exception 'item_not_found: %', p->>'id';
    end if;
  elsif p->>'title' is not null then
    if v_area is null then
      raise exception 'area_required';
    end if;
    select * into v_row from items
    where area_id = v_area and lower(title) = lower(trim(p->>'title')) and status <> 'done'
    order by created_at desc
    limit 1;
  else
    raise exception 'id_or_title_required';
  end if;

  if v_row.id is null then
    insert into items (area_id, title) values (v_area, trim(p->>'title')) returning * into v_row;
    v_action := 'created';
  else
    v_action := 'updated';
  end if;

  v_status := coalesce(p->>'status', v_row.status);
  update items set
    area_id    = coalesce(v_area, area_id),
    parent_id  = case when p ? 'parent_id' then (p->>'parent_id')::uuid else parent_id end,
    title      = coalesce(trim(p->>'title'), title),
    status     = v_status,
    progress   = case when v_status = 'done' then 100 else coalesce((p->>'progress')::smallint, progress) end,
    priority   = coalesce((p->>'priority')::smallint, priority),
    due_date   = case when p ? 'due' then (p->>'due')::timestamptz else due_date end,
    recurrence = case when p ? 'recurrence' then p->>'recurrence' else recurrence end,
    tags       = case when p ? 'tags' then coalesce(array(select jsonb_array_elements_text(p->'tags')), '{}') else tags end,
    data       = case when p ? 'data' then data || coalesce(p->'data', '{}') else data end,
    completed_at = case
      when v_status = 'done' and completed_at is null then now()
      when v_status <> 'done' then null
      else completed_at end
  where id = v_row.id
  returning * into v_row;

  return jsonb_build_object('action', v_action, 'item', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_complete_item(p_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row items;
begin
  update items set status = 'done', progress = 100, completed_at = coalesce(completed_at, now())
  where id = p_id
  returning * into v_row;
  if v_row.id is null then
    raise exception 'item_not_found: %', p_id;
  end if;
  return jsonb_build_object('action', 'completed', 'item', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_delete_item(p_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_title text;
begin
  delete from items where id = p_id returning title into v_title;
  if v_title is null then
    raise exception 'item_not_found: %', p_id;
  end if;
  return jsonb_build_object('action', 'deleted', 'id', p_id, 'title', v_title);
end;
$$;

create or replace function public.ai_log_entry(p_area text, p_note text, p_item_id uuid default null, p_logged_at timestamptz default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row logs;
begin
  insert into logs (area_id, item_id, note, logged_at)
  values (ai_area_id(p_area), p_item_id, p_note, coalesce(p_logged_at, now()))
  returning * into v_row;
  return jsonb_build_object('action', 'logged', 'log', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_record_metric(p_area text, p_name text, p_value double precision, p_unit text default null, p_recorded_at timestamptz default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row metrics;
begin
  insert into metrics (area_id, name, value, unit, recorded_at, source)
  values (ai_area_id(p_area), lower(trim(p_name)), p_value, p_unit, coalesce(p_recorded_at, now()), 'ai')
  returning * into v_row;
  return jsonb_build_object('action', 'recorded', 'metric', to_jsonb(v_row));
end;
$$;

-- query_area: items, logs, metrics (and Hevy workouts for gym areas) in a date range.
-- Default range: last 30 days. Items are filtered by due/updated date only when a range is given.
create or replace function public.ai_query_area(
  p_area text,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_status text default null,
  p_tag text default null,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_area areas;
  v_from timestamptz := coalesce(p_from, now() - interval '30 days');
  v_to timestamptz := coalesce(p_to, now());
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_result jsonb;
begin
  select * into v_area from areas where id = ai_area_id(p_area);

  v_result := jsonb_build_object(
    'area', jsonb_build_object('id', v_area.id, 'name', v_area.name, 'kind', v_area.kind),
    'range', jsonb_build_object('from', v_from, 'to', v_to),
    'items', coalesce((
      select jsonb_agg(to_jsonb(i) - 'user_id' - 'created_at' order by i.status = 'done', i.due_date nulls last, i.priority desc)
      from (
        select * from items
        where area_id = v_area.id
          and (p_status is null or status = p_status)
          and (p_tag is null or p_tag = any (tags))
          and (p_from is null and p_to is null
               or coalesce(due_date, completed_at, updated_at) between v_from and v_to)
        order by status = 'done', due_date nulls last
        limit v_limit
      ) i), '[]'),
    'logs', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'item_id', l.item_id, 'note', l.note, 'data', l.data, 'logged_at', l.logged_at) order by l.logged_at desc)
      from (
        select * from logs where area_id = v_area.id and logged_at between v_from and v_to
        order by logged_at desc limit v_limit
      ) l), '[]'),
    'metrics', coalesce((
      select jsonb_agg(jsonb_build_object('name', m.name, 'value', m.value, 'unit', m.unit, 'recorded_at', m.recorded_at) order by m.recorded_at desc)
      from (
        select * from metrics where area_id = v_area.id and recorded_at between v_from and v_to
        order by recorded_at desc limit v_limit
      ) m), '[]')
  );

  if v_area.kind = 'gym' then
    v_result := v_result || jsonb_build_object('workouts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', w.id, 'title', w.title, 'started_at', w.started_at, 'ended_at', w.ended_at,
        'exercises', (
          select coalesce(jsonb_agg(e order by (e->>'index')::int), '[]')
          from (
            select jsonb_build_object(
              'index', s.exercise_index,
              'exercise', s.exercise_title,
              'sets', count(*) filter (where coalesce(s.set_type, 'normal') <> 'warmup'),
              'top_weight_kg', max(s.weight_kg),
              'max_reps', max(s.reps),
              'volume_kg', round(sum(coalesce(s.weight_kg, 0) * coalesce(s.reps, 0)) filter (where coalesce(s.set_type, 'normal') <> 'warmup')::numeric, 1)
            ) as e
            from workout_sets s
            where s.workout_id = w.id
            group by s.exercise_index, s.exercise_title
          ) x)
      ) order by w.started_at desc)
      from (
        select * from workouts where started_at between v_from and v_to
        order by started_at desc limit v_limit
      ) w), '[]'));
  end if;

  return v_result;
end;
$$;

-- get_dashboard_summary: one compact row per visible area (or one area).
create or replace function public.ai_dashboard_summary(p_area text default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_only uuid;
begin
  if p_area is not null then
    v_only := ai_area_id(p_area);
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id,
      'name', a.name,
      'kind', a.kind,
      'pinned', a.pinned,
      'open_items', (select count(*) from items i where i.area_id = a.id and i.status <> 'done'),
      'overdue', (select count(*) from items i where i.area_id = a.id and i.status <> 'done' and i.due_date < now()),
      'done_last_7d', (select count(*) from items i where i.area_id = a.id and i.completed_at > now() - interval '7 days'),
      'logs_last_7d', (select count(*) from logs l where l.area_id = a.id and l.logged_at > now() - interval '7 days'),
      'latest_metrics', (
        select coalesce(jsonb_agg(jsonb_build_object('name', m.name, 'value', m.value, 'unit', m.unit, 'recorded_at', m.recorded_at)), '[]')
        from (
          select distinct on (name) name, value, unit, recorded_at
          from metrics where area_id = a.id
          order by name, recorded_at desc
          limit 8
        ) m),
      'workouts_last_7d', case when a.kind = 'gym'
        then (select count(*) from workouts w where w.started_at > now() - interval '7 days') end
    ) order by a.pinned desc, a.sort_order, a.name)
    from areas a
    where (v_only is null and not a.hidden) or a.id = v_only
  ), '[]');
end;
$$;

-- get_daily_briefing: what's due, what's behind, what I did yesterday (in the user's timezone).
create or replace function public.ai_daily_briefing()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_tz text := ai_tz();
  v_today date := (now() at time zone v_tz)::date;
  v_start timestamptz := v_today::timestamp at time zone v_tz;
  v_end timestamptz := (v_today + 1)::timestamp at time zone v_tz;
  v_yesterday timestamptz := (v_today - 1)::timestamp at time zone v_tz;
begin
  return jsonb_build_object(
    'date', v_today,
    'timezone', v_tz,
    'due_today', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'title', i.title, 'area', a.name, 'due', i.due_date, 'priority', i.priority) order by i.due_date)
      from items i join areas a on a.id = i.area_id
      where i.status <> 'done' and i.due_date >= v_start and i.due_date < v_end), '[]'),
    'overdue_count', (select count(*) from items where status <> 'done' and due_date < v_start),
    'overdue', coalesce((
      select jsonb_agg(x order by x->>'due')
      from (
        select jsonb_build_object('id', i.id, 'title', i.title, 'area', a.name, 'due', i.due_date) as x
        from items i join areas a on a.id = i.area_id
        where i.status <> 'done' and i.due_date < v_start
        order by i.priority desc, i.due_date
        limit 10
      ) o), '[]'),
    'reminders_today', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.id, 'title', r.title, 'remind_at', r.remind_at) order by r.remind_at)
      from reminders r
      where r.completed_at is null and r.sync_status <> 'pending_delete'
        and r.remind_at >= v_start and r.remind_at < v_end), '[]'),
    'yesterday', jsonb_build_object(
      'completed', coalesce((
        select jsonb_agg(jsonb_build_object('title', i.title, 'area', a.name))
        from items i join areas a on a.id = i.area_id
        where i.completed_at >= v_yesterday and i.completed_at < v_start), '[]'),
      'logs', (select count(*) from logs where logged_at >= v_yesterday and logged_at < v_start),
      'workouts', coalesce((
        select jsonb_agg(jsonb_build_object('title', w.title, 'started_at', w.started_at))
        from workouts w
        where w.started_at >= v_yesterday and w.started_at < v_start), '[]')
    ),
    'checkin_today', (
      select jsonb_build_object('type', c.type, 'mood', c.mood, 'energy', c.energy, 'wins', c.wins)
      from checkins c where c.date = v_today
      order by c.type desc limit 1)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Reminder tools. The row is the source of truth; the app writes EventKit on-device
-- (sync_status = pending_push / pending_delete tells it what to do).
-- ---------------------------------------------------------------------------

create or replace function public.ai_create_reminder(p jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row reminders;
begin
  if p->>'title' is null or p->>'remind_at' is null then
    raise exception 'title_and_remind_at_required';
  end if;
  insert into reminders (title, notes, remind_at, repeat_rule, area_id, item_id, notify_mode, sync_status, source_modified_at)
  values (
    trim(p->>'title'),
    p->>'notes',
    (p->>'remind_at')::timestamptz,
    p->>'repeat',
    case when p->>'area' is not null then ai_area_id(p->>'area') end,
    (p->>'item_id')::uuid,
    coalesce(p->>'notify_mode', (select default_notify_mode from user_settings where user_id = auth.uid()), 'app'),
    'pending_push',
    now()
  )
  returning * into v_row;
  return jsonb_build_object('action', 'created', 'reminder', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_update_reminder(p jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row reminders;
begin
  update reminders set
    title       = coalesce(trim(p->>'title'), title),
    notes       = case when p ? 'notes' then p->>'notes' else notes end,
    remind_at   = case when p ? 'remind_at' then (p->>'remind_at')::timestamptz else remind_at end,
    repeat_rule = case when p ? 'repeat' then p->>'repeat' else repeat_rule end,
    area_id     = case when p ? 'area' then (case when p->>'area' is null then null else ai_area_id(p->>'area') end) else area_id end,
    notify_mode = coalesce(p->>'notify_mode', notify_mode),
    sync_status = 'pending_push',
    source_modified_at = now()
  where id = (p->>'id')::uuid
  returning * into v_row;
  if v_row.id is null then
    raise exception 'reminder_not_found: %', p->>'id';
  end if;
  return jsonb_build_object('action', 'updated', 'reminder', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_complete_reminder(p_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row reminders;
begin
  update reminders set completed_at = coalesce(completed_at, now()), sync_status = 'pending_push', source_modified_at = now()
  where id = p_id
  returning * into v_row;
  if v_row.id is null then
    raise exception 'reminder_not_found: %', p_id;
  end if;
  return jsonb_build_object('action', 'completed', 'reminder', to_jsonb(v_row));
end;
$$;

-- Not yet in Apple Reminders: delete now. Otherwise mark pending_delete; the app deletes
-- the EKReminder, then the row.
create or replace function public.ai_delete_reminder(p_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row reminders;
begin
  select * into v_row from reminders where id = p_id;
  if v_row.id is null then
    raise exception 'reminder_not_found: %', p_id;
  end if;
  if v_row.apple_reminder_id is null then
    delete from reminders where id = p_id;
    return jsonb_build_object('action', 'deleted', 'reminder', to_jsonb(v_row));
  end if;
  update reminders set sync_status = 'pending_delete', source_modified_at = now()
  where id = p_id
  returning * into v_row;
  return jsonb_build_object('action', 'pending_delete', 'reminder', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_list_reminders(p_area text default null, p_from timestamptz default null, p_to timestamptz default null, p_include_done boolean default false)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_area uuid;
begin
  if p_area is not null then
    v_area := ai_area_id(p_area);
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'title', r.title, 'notes', r.notes, 'remind_at', r.remind_at, 'repeat', r.repeat_rule,
      'notify_mode', r.notify_mode, 'area_id', r.area_id, 'completed_at', r.completed_at
    ) order by r.remind_at nulls last)
    from reminders r
    where (v_area is null or r.area_id = v_area)
      and (p_include_done or r.completed_at is null)
      and r.sync_status <> 'pending_delete'
      and (p_from is null or r.remind_at >= p_from)
      and (p_to is null or r.remind_at < p_to)
  ), '[]');
end;
$$;

-- ---------------------------------------------------------------------------
-- Only signed-in users may call these.
-- ---------------------------------------------------------------------------

do $$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'ai\_%'
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
