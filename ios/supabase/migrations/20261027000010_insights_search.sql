-- Phase 14: insights (computed here, with sample sizes; the AI only phrases them), nudges, universal search.

-- Recomputes insights from your data. Only surfaces a finding when both groups have enough data.
create or replace function public.ai_compute_insights()
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_tz text := ai_tz();
  v_added int := 0;
  r record;
begin
  -- Fresh run: drop earlier undismissed computed insights (dismissed ones are kept so they don't come back).
  delete from insights where not dismissed and kind in ('correlation', 'trend');

  -- 1. Sleep the night before workout days vs other days (last 90 days).
  select
    round(avg(s.value) filter (where w.day is not null)::numeric, 1) as with_w,
    round(avg(s.value) filter (where w.day is null)::numeric, 1) as without_w,
    count(*) filter (where w.day is not null) as n_w,
    count(*) filter (where w.day is null) as n_o
  into r
  from (select (recorded_at at time zone v_tz)::date as day, value from metrics
        where name = 'sleep_hours' and recorded_at > now() - interval '90 days') s
  left join (select distinct (started_at at time zone v_tz)::date as day from workouts) w on w.day = s.day;
  if r.n_w >= 7 and r.n_o >= 7 and abs(r.with_w - r.without_w) >= 0.3 then
    insert into insights (text, kind, sample_size)
    values (format('You sleep %s h before workout days vs %s h otherwise.', r.with_w, r.without_w), 'correlation', r.n_w + r.n_o);
    v_added := v_added + 1;
  end if;

  -- 2. Mood on workout days vs rest days (check-ins, last 90 days).
  select
    round(avg(c.mood) filter (where w.day is not null)::numeric, 1) as with_w,
    round(avg(c.mood) filter (where w.day is null)::numeric, 1) as without_w,
    count(*) filter (where w.day is not null) as n_w,
    count(*) filter (where w.day is null) as n_o
  into r
  from (select date as day, avg(mood) as mood from checkins where mood is not null and date > current_date - 90 group by date) c
  left join (select distinct (started_at at time zone v_tz)::date as day from workouts) w on w.day = c.day;
  if r.n_w >= 5 and r.n_o >= 5 and abs(r.with_w - r.without_w) >= 0.5 then
    insert into insights (text, kind, sample_size)
    values (format('Your mood averages %s on workout days and %s on rest days.', r.with_w, r.without_w), 'correlation', r.n_w + r.n_o);
    v_added := v_added + 1;
  end if;

  -- 3. Trends over 4 weeks for bodyweight and sleep (first vs last week averages).
  for r in
    select name, unit, count(*) n,
           round(avg(value) filter (where recorded_at > now() - interval '7 days')::numeric, 1) as recent,
           round(avg(value) filter (where recorded_at <= now() - interval '21 days')::numeric, 1) as earlier,
           count(*) filter (where recorded_at > now() - interval '7 days') as n_recent,
           count(*) filter (where recorded_at <= now() - interval '21 days') as n_earlier
    from metrics where name in ('bodyweight', 'sleep_hours', 'resting_hr') and recorded_at > now() - interval '28 days'
    group by name, unit
  loop
    if r.n_recent >= 3 and r.n_earlier >= 3 and r.recent is not null and r.earlier is not null
       and abs(r.recent - r.earlier) >= (case r.name when 'bodyweight' then 0.5 when 'sleep_hours' then 0.4 else 2 end) then
      insert into insights (text, kind, sample_size)
      values (format('%s is %s %s%s over 4 weeks (%s to %s).',
                     initcap(replace(r.name, '_', ' ')), case when r.recent > r.earlier then 'up' else 'down' end,
                     abs(r.recent - r.earlier), coalesce(' ' || r.unit, ''), r.earlier, r.recent), 'trend', r.n);
      v_added := v_added + 1;
    end if;
  end loop;

  return jsonb_build_object('added', v_added);
end;
$$;

create or replace function public.ai_get_insights()
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'text', text, 'kind', kind, 'sample_size', sample_size, 'created_at', created_at)
                            order by created_at desc), '[]')
  from insights where not dismissed;
$$;

create or replace function public.ai_dismiss_insight(p_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
begin
  update insights set dismissed = true where id = p_id;
  if not found then raise exception 'insight_not_found: %', p_id; end if;
  return jsonb_build_object('action', 'dismissed');
end;
$$;

-- Nudges: gentle, rule-based. The app rate-limits and respects quiet hours.
create or replace function public.ai_nudges()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_out jsonb := '[]';
  v_days int;
  v_n int;
  r record;
begin
  -- No weight logged in 5+ days (only if you've logged weight in the last 60 days).
  select extract(day from now() - max(recorded_at))::int into v_days from metrics
  where name = 'bodyweight' and recorded_at > now() - interval '60 days';
  if v_days >= 5 then
    v_out := v_out || jsonb_build_object('kind', 'bodyweight', 'text', format('No weight logged in %s days.', v_days));
  end if;
  -- No workout in 5+ days, if you usually train (4+ workouts in the last 30 days before that).
  select count(*) into v_n from workouts where started_at > now() - interval '35 days';
  select extract(day from now() - max(started_at))::int into v_days from workouts;
  if v_n >= 4 and v_days >= 5 then
    v_out := v_out || jsonb_build_object('kind', 'workout', 'text', format('No workout in %s days.', v_days));
  end if;
  -- Habits not done for 3+ days.
  for r in
    select i.title, coalesce(extract(day from now() - max(l.logged_at))::int, extract(day from now() - i.created_at)::int) as days
    from items i left join logs l on l.item_id = i.id
    where i.recurrence is not null and i.status <> 'done'
    group by i.id, i.title, i.created_at
    having coalesce(extract(day from now() - max(l.logged_at))::int, extract(day from now() - i.created_at)::int) >= 3
    limit 3
  loop
    v_out := v_out || jsonb_build_object('kind', 'habit', 'text', format('%s: not done in %s days.', r.title, r.days));
  end loop;
  -- Pile of overdue items.
  select count(*) into v_n from items where status <> 'done' and due_date < now() - interval '1 day';
  if v_n >= 3 then
    v_out := v_out || jsonb_build_object('kind', 'overdue', 'text', format('%s items are overdue.', v_n));
  end if;
  return v_out;
end;
$$;

-- search_all: one query across everything you've stored.
create or replace function public.ai_search_all(p_query text, p_limit int default 30)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  q text := '%' || replace(replace(trim(p_query), '%', '\%'), '_', '\_') || '%';
begin
  if length(trim(coalesce(p_query, ''))) < 2 then
    return '[]';
  end if;
  return coalesce((select jsonb_agg(x order by (x->>'date') desc nulls last) from (
    select jsonb_build_object('type', 'item', 'id', i.id, 'title', i.title, 'snippet', a.name, 'date', coalesce(i.completed_at, i.updated_at)) x
      from items i join areas a on a.id = i.area_id where i.title ilike q or array_to_string(i.tags, ' ') ilike q
    union all
    select jsonb_build_object('type', 'log', 'id', l.id, 'title', l.note, 'snippet', a.name, 'date', l.logged_at)
      from logs l join areas a on a.id = l.area_id where l.note ilike q
    union all
    select jsonb_build_object('type', 'reminder', 'id', r.id, 'title', r.title, 'snippet', r.notes, 'date', r.remind_at)
      from reminders r where r.title ilike q or r.notes ilike q
    union all
    select jsonb_build_object('type', 'journal', 'id', j.id, 'title', j.date::text, 'snippet', left(j.content, 140), 'date', j.date)
      from journal_entries j where j.content ilike q
    union all
    select jsonb_build_object('type', 'capture', 'id', c.id, 'title', c.raw_text, 'snippet', c.status, 'date', c.created_at)
      from captures c where c.raw_text ilike q
    union all
    select jsonb_build_object('type', 'workout', 'id', w.id, 'title', w.title, 'snippet', null, 'date', w.started_at)
      from workouts w where w.title ilike q
    union all
    select jsonb_build_object('type', 'exercise', 'id', s.workout_id, 'title', s.exercise_title,
                              'snippet', coalesce(s.weight_kg::text || ' kg × ', '') || coalesce(s.reps::text, ''), 'date', w.started_at)
      from (select distinct on (workout_id, exercise_title) * from workout_sets
            where exercise_title ilike q order by workout_id, exercise_title, weight_kg desc nulls last) s
      join workouts w on w.id = s.workout_id
    union all
    select jsonb_build_object('type', 'person', 'id', p.id, 'title', p.name, 'snippet', p.notes, 'date', p.last_contacted)
      from people p where p.name ilike q or p.notes ilike q
    union all
    select jsonb_build_object('type', 'document', 'id', d.id, 'title', d.title, 'snippet', d.location_note, 'date', d.expires_at)
      from documents d where d.title ilike q or d.notes ilike q or d.location_note ilike q or d.category ilike q
    union all
    select jsonb_build_object('type', 'subscription', 'id', s.id, 'title', s.name, 'snippet', s.amount::text || ' ' || s.currency, 'date', s.renews_on)
      from subscriptions s where s.name ilike q
    limit greatest(1, least(coalesce(p_limit, 30), 100))
  ) t), '[]');
end;
$$;

-- search_workouts: "when did I last deadlift 200?" Sets matching an exercise (and optional minimum weight / reps), newest first.
create or replace function public.ai_search_workouts(p_exercise text, p_min_weight_kg double precision default null, p_min_reps int default null, p_limit int default 10)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(jsonb_agg(x), '[]') from (
    select jsonb_build_object('date', w.started_at, 'workout', w.title, 'exercise', s.exercise_title,
                              'weight_kg', s.weight_kg, 'reps', s.reps, 'set_type', s.set_type) x
    from workout_sets s join workouts w on w.id = s.workout_id
    where s.exercise_title ilike '%' || p_exercise || '%'
      and (p_min_weight_kg is null or s.weight_kg >= p_min_weight_kg)
      and (p_min_reps is null or s.reps >= p_min_reps)
      and coalesce(s.set_type, 'normal') <> 'warmup'
    order by w.started_at desc, s.weight_kg desc nulls last
    limit greatest(1, least(coalesce(p_limit, 10), 50))
  ) t;
$$;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('ai_compute_insights', 'ai_get_insights', 'ai_dismiss_insight', 'ai_nudges', 'ai_search_all', 'ai_search_workouts')
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

-- get_insights(refresh: true): recompute, then list.
create or replace function public.ai_compute_insights_then_get()
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
begin
  perform ai_compute_insights();
  return ai_get_insights();
end;
$$;
revoke all on function public.ai_compute_insights_then_get() from public, anon;
grant execute on function public.ai_compute_insights_then_get() to authenticated;
