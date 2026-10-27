-- Phase 9: check-ins, weekly review, daily journal.

alter table public.user_settings
  add column if not exists checkin_morning_time time,
  add column if not exists checkin_evening_time time;

-- submit_checkin: one per (date, type); a second submit updates it.
create or replace function public.ai_submit_checkin(p jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row checkins;
  v_date date := coalesce((p->>'date')::date, (now() at time zone ai_tz())::date);
begin
  insert into checkins (type, mood, energy, wins, notes, date)
  values (p->>'type', (p->>'mood')::smallint, (p->>'energy')::smallint, p->>'wins', p->>'notes', v_date)
  on conflict (user_id, date, type) do update set
    mood = coalesce(excluded.mood, checkins.mood),
    energy = coalesce(excluded.energy, checkins.energy),
    wins = coalesce(excluded.wins, checkins.wins),
    notes = coalesce(excluded.notes, checkins.notes)
  returning * into v_row;
  return jsonb_build_object('action', 'saved', 'checkin', to_jsonb(v_row));
end;
$$;

-- get_weekly_review: facts for the week starting p_week_start (Monday, user's timezone). The model only
-- summarizes these; every number comes from here.
create or replace function public.ai_weekly_review(p_week_start date default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_tz text := ai_tz();
  v_today date := (now() at time zone v_tz)::date;
  v_week date := coalesce(p_week_start, v_today - ((extract(isodow from v_today)::int) - 1));
  v_from timestamptz := v_week::timestamp at time zone v_tz;
  v_to timestamptz := (v_week + 7)::timestamp at time zone v_tz;
begin
  return jsonb_build_object(
    'week_start', v_week,
    'week_end', v_week + 6,
    'areas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'area', a.name,
        'kind', a.kind,
        'completed', (select coalesce(jsonb_agg(i.title), '[]') from items i
                      where i.area_id = a.id and i.completed_at >= v_from and i.completed_at < v_to),
        'missed', (select coalesce(jsonb_agg(i.title), '[]') from items i
                   where i.area_id = a.id and i.status <> 'done' and i.due_date >= v_from and i.due_date < v_to),
        'logs', (select count(*) from logs l where l.area_id = a.id and l.logged_at >= v_from and l.logged_at < v_to),
        'metrics', (select coalesce(jsonb_agg(jsonb_build_object('name', m.name, 'count', m.n, 'avg', m.avg, 'min', m.min, 'max', m.max, 'sum', m.sum, 'unit', m.unit)), '[]')
                    from (select name, count(*) n, round(avg(value)::numeric, 2) avg, min(value) min, max(value) max,
                                 round(sum(value)::numeric, 2) sum, max(unit) unit
                          from metrics where area_id = a.id and recorded_at >= v_from and recorded_at < v_to
                          group by name) m),
        'habits', (select coalesce(jsonb_agg(jsonb_build_object('habit', i.title,
                      'days_done', (select count(distinct (l.logged_at at time zone v_tz)::date) from logs l
                                    where l.item_id = i.id and l.logged_at >= v_from and l.logged_at < v_to))), '[]')
                   from items i where i.area_id = a.id and i.recurrence is not null and i.status <> 'done')
      ) order by a.sort_order)
      from areas a where not a.hidden), '[]'),
    'workouts', (select count(*) from workouts w where w.started_at >= v_from and w.started_at < v_to),
    'checkins', (select jsonb_build_object('count', count(*), 'avg_mood', round(avg(mood)::numeric, 1), 'avg_energy', round(avg(energy)::numeric, 1))
                 from checkins c where c.date >= v_week and c.date < v_week + 7)
  );
end;
$$;

-- Everything from one day, for the daily journal.
create or replace function public.ai_day_digest(p_date date default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_tz text := ai_tz();
  v_day date := coalesce(p_date, (now() at time zone v_tz)::date);
  v_from timestamptz := v_day::timestamp at time zone v_tz;
  v_to timestamptz := (v_day + 1)::timestamp at time zone v_tz;
begin
  return jsonb_build_object(
    'date', v_day,
    'completed', coalesce((select jsonb_agg(jsonb_build_object('title', i.title, 'area', a.name))
                           from items i join areas a on a.id = i.area_id
                           where i.completed_at >= v_from and i.completed_at < v_to), '[]'),
    'logs', coalesce((select jsonb_agg(jsonb_build_object('area', a.name, 'note', l.note, 'item', i.title, 'at', l.logged_at) order by l.logged_at)
                      from logs l join areas a on a.id = l.area_id left join items i on i.id = l.item_id
                      where l.logged_at >= v_from and l.logged_at < v_to), '[]'),
    'metrics', coalesce((select jsonb_agg(jsonb_build_object('area', a.name, 'name', m.name, 'value', m.value, 'unit', m.unit))
                         from metrics m join areas a on a.id = m.area_id
                         where m.recorded_at >= v_from and m.recorded_at < v_to and m.source <> 'healthkit'), '[]'),
    'health', coalesce((select jsonb_object_agg(m.name, m.value)
                        from metrics m where m.source = 'healthkit' and m.external_id like '%:' || v_day::text), '{}'),
    'workouts', coalesce((select jsonb_agg(jsonb_build_object('title', w.title, 'sets', (select count(*) from workout_sets s where s.workout_id = w.id)))
                          from workouts w where w.started_at >= v_from and w.started_at < v_to), '[]'),
    'checkins', coalesce((select jsonb_agg(jsonb_build_object('type', c.type, 'mood', c.mood, 'energy', c.energy, 'wins', c.wins, 'notes', c.notes))
                          from checkins c where c.date = v_day), '[]')
  );
end;
$$;

-- Saves the AI journal for a day, without overwriting an entry you wrote or edited yourself.
create or replace function public.ai_save_journal(p_date date, p_content text)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row journal_entries;
begin
  insert into journal_entries (date, content, source) values (p_date, p_content, 'ai')
  on conflict (user_id, date) do update set content = excluded.content
    where journal_entries.source = 'ai'
  returning * into v_row;
  if v_row.id is null then
    return jsonb_build_object('action', 'kept_manual');
  end if;
  return jsonb_build_object('action', 'saved', 'journal', to_jsonb(v_row));
end;
$$;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('ai_submit_checkin', 'ai_weekly_review', 'ai_day_digest', 'ai_save_journal')
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
