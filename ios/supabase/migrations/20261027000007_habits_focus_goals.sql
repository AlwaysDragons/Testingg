-- Phase 11: habits + streaks, focus sessions, goal progress roll-up.

-- log_habit: one completion per habit per day (idempotent).
create or replace function public.ai_log_habit(p_item_id uuid, p_date date default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_tz text := ai_tz();
  v_day date := coalesce(p_date, (now() at time zone v_tz)::date);
  v_item items;
  v_log logs;
begin
  select * into v_item from items where id = p_item_id;
  if v_item.id is null then
    raise exception 'item_not_found: %', p_item_id;
  end if;
  select * into v_log from logs
  where item_id = p_item_id and (logged_at at time zone v_tz)::date = v_day
  limit 1;
  if v_log.id is null then
    insert into logs (area_id, item_id, note, data, logged_at)
    values (v_item.area_id, v_item.id, null, '{"habit": true}',
            case when v_day = (now() at time zone v_tz)::date then now() else (v_day::timestamp + interval '12 hours') at time zone v_tz end)
    returning * into v_log;
  end if;
  return jsonb_build_object('action', 'logged', 'log', to_jsonb(v_log), 'streak', ai_habit_streak(p_item_id));
end;
$$;

-- Streak rules (per habit, in items.data): "grace" = missed days allowed without breaking the streak (default 0);
-- "skip_days" = ISO weekdays that don't count (e.g. [6,7] for weekends). Today not yet done doesn't break it.
create or replace function public.ai_habit_streak(p_item_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_tz text := ai_tz();
  v_today date := (now() at time zone v_tz)::date;
  v_item items;
  v_grace int;
  v_skip int[];
  v_days date[];
  v_day date;
  v_current int := 0;
  v_longest int := 0;
  v_run int := 0;
  v_missed int := 0;
  v_counting boolean := true;
  v_first date;
begin
  select * into v_item from items where id = p_item_id;
  if v_item.id is null then return null; end if;
  v_grace := coalesce((v_item.data->>'grace')::int, 0);
  v_skip := coalesce(array(select jsonb_array_elements_text(v_item.data->'skip_days')::int), '{}');
  select coalesce(array_agg(distinct (logged_at at time zone v_tz)::date), '{}') into v_days from logs where item_id = p_item_id;
  v_first := least(coalesce((select min(d) from unnest(v_days) d), v_today), (v_item.created_at at time zone v_tz)::date);

  -- Walk back from today: current streak (stops at the first break), then longest over all history.
  v_day := v_today;
  while v_day >= v_first loop
    if extract(isodow from v_day)::int = any (v_skip) then
      null;
    elsif v_day = any (v_days) then
      v_run := v_run + 1;
      v_missed := 0;
    elsif v_day = v_today then
      null;  -- today isn't over yet
    else
      v_missed := v_missed + 1;
      if v_missed > v_grace then
        if v_counting then v_current := v_run; v_counting := false; end if;
        v_longest := greatest(v_longest, v_run);
        v_run := 0;
        v_missed := 0;
      end if;
    end if;
    v_day := v_day - 1;
  end loop;
  if v_counting then v_current := v_run; end if;
  v_longest := greatest(v_longest, v_run);

  return jsonb_build_object(
    'item_id', v_item.id, 'title', v_item.title, 'current', v_current, 'longest', v_longest,
    'done_today', v_today = any (v_days),
    'last_7', (select count(*) from unnest(v_days) d where d > v_today - 7));
end;
$$;

-- get_streaks: every open habit (optionally in one area).
create or replace function public.ai_streaks(p_area text default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_area uuid;
begin
  if p_area is not null then v_area := ai_area_id(p_area); end if;
  return coalesce((
    select jsonb_agg(ai_habit_streak(i.id) || jsonb_build_object('area_id', i.area_id) order by i.title)
    from items i
    where i.recurrence is not null and i.status <> 'done' and (v_area is null or i.area_id = v_area)
  ), '[]');
end;
$$;

-- Focus sessions are logs with data {"focus": true, "started_at", "planned_minutes", "ended_at", "minutes"}.
create or replace function public.ai_start_focus(p_area text, p_minutes int default 25)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row logs;
begin
  perform ai_end_focus();   -- one session at a time
  insert into logs (area_id, note, data)
  values (ai_area_id(p_area), 'Focus session',
          jsonb_build_object('focus', true, 'started_at', now(), 'planned_minutes', greatest(1, least(coalesce(p_minutes, 25), 240))))
  returning * into v_row;
  return jsonb_build_object('action', 'started', 'log', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_end_focus()
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row logs;
  v_minutes int;
begin
  select * into v_row from logs
  where data->>'focus' = 'true' and not (data ? 'ended_at')
  order by logged_at desc limit 1;
  if v_row.id is null then
    return jsonb_build_object('action', 'none');
  end if;
  v_minutes := least(round(extract(epoch from now() - (v_row.data->>'started_at')::timestamptz) / 60)::int,
                     (v_row.data->>'planned_minutes')::int * 2);
  update logs set data = data || jsonb_build_object('ended_at', now(), 'minutes', greatest(v_minutes, 0)),
                  note = 'Focus ' || greatest(v_minutes, 0) || ' min'
  where id = v_row.id
  returning * into v_row;
  return jsonb_build_object('action', 'ended', 'log', to_jsonb(v_row), 'minutes', greatest(v_minutes, 0));
end;
$$;

-- Total focus minutes per area over the last p_days days.
create or replace function public.ai_focus_totals(p_days int default 7)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('area_id', area_id, 'area', name, 'minutes', minutes) order by minutes desc), '[]')
  from (
    select l.area_id, a.name, sum((l.data->>'minutes')::int) minutes
    from logs l join areas a on a.id = l.area_id
    where l.data->>'focus' = 'true' and l.data ? 'minutes' and l.logged_at > now() - make_interval(days => p_days)
    group by l.area_id, a.name
  ) t;
$$;

-- Goals with milestones: a parent's progress = share of its milestones done.
create or replace function public.rollup_parent_progress()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_parent uuid := coalesce(new.parent_id, old.parent_id);
  v_total int;
  v_done int;
begin
  if tg_op = 'UPDATE' and old.parent_id is distinct from new.parent_id and old.parent_id is not null then
    -- moved: refresh the old parent too
    select count(*), count(*) filter (where status = 'done') into v_total, v_done from items where parent_id = old.parent_id;
    update items set progress = case when v_total = 0 then progress else round(100.0 * v_done / v_total) end
    where id = old.parent_id;
  end if;
  if v_parent is null then return null; end if;
  select count(*), count(*) filter (where status = 'done') into v_total, v_done from items where parent_id = v_parent;
  update items set
    progress = case when v_total = 0 then progress else round(100.0 * v_done / v_total) end,
    status = case when status = 'done' or v_total = 0 then status when v_done > 0 then 'in_progress' else status end
  where id = v_parent and progress is distinct from (case when v_total = 0 then progress else round(100.0 * v_done / v_total) end);
  return null;
end;
$$;

drop trigger if exists items_rollup on public.items;
create trigger items_rollup
  after insert or delete or update of status, parent_id on public.items
  for each row execute function public.rollup_parent_progress();

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('ai_log_habit', 'ai_habit_streak', 'ai_streaks', 'ai_start_focus', 'ai_end_focus', 'ai_focus_totals')
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
