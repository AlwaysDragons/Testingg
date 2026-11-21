-- Phase 17 (polish). Safe to re-run.

-- Next occurrence of a simple RRULE (FREQ + INTERVAL) after now, stepping from p_from.
-- Null when the rule has no FREQ the app understands.
create or replace function public.rrule_next(p_rule text, p_from timestamptz, p_now timestamptz default now())
returns timestamptz
language plpgsql
immutable
set search_path = public
as $$
declare
  v_freq text := substring(upper(coalesce(p_rule, '')) from 'FREQ=([A-Z]+)');
  v_int int := greatest(1, coalesce(substring(upper(p_rule) from 'INTERVAL=([0-9]+)')::int, 1));
  v_step interval;
  v_n int := 1;
  v_next timestamptz;
begin
  v_step := case v_freq
    when 'DAILY' then make_interval(days => v_int)
    when 'WEEKLY' then make_interval(weeks => v_int)
    when 'MONTHLY' then make_interval(months => v_int)
    when 'YEARLY' then make_interval(years => v_int)
  end;
  if v_step is null or p_from is null then
    return null;
  end if;
  -- Multiply from the original date so month ends don't drift (Jan 31 -> Feb 28 -> Mar 31).
  v_next := p_from + v_step;
  while v_next <= p_now and v_n < 5000 loop
    v_n := v_n + 1;
    v_next := p_from + v_step * v_n;
  end loop;
  return v_next;
end;
$$;

-- Completing a repeating reminder moves it to its next occurrence (like Apple Reminders).
create or replace function public.ai_complete_reminder(p_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row reminders;
  v_next timestamptz;
begin
  select * into v_row from reminders where id = p_id;
  if v_row.id is null then
    raise exception 'reminder_not_found: %', p_id;
  end if;
  v_next := rrule_next(v_row.repeat_rule, v_row.remind_at);
  if v_next is not null and v_row.completed_at is null then
    update reminders set remind_at = v_next, sync_status = 'pending_push', source_modified_at = now()
    where id = p_id returning * into v_row;
    return jsonb_build_object('action', 'advanced', 'next', v_next, 'reminder', to_jsonb(v_row));
  end if;
  update reminders set completed_at = coalesce(completed_at, now()), sync_status = 'pending_push', source_modified_at = now()
  where id = p_id
  returning * into v_row;
  return jsonb_build_object('action', 'completed', 'reminder', to_jsonb(v_row));
end;
$$;

-- The app's editors pass the row id, so renaming a person or document updates it instead of adding a copy,
-- and removing a gift idea in the editor sticks (the assistant, without an id, still merges by name).
create or replace function public.ai_add_person(p jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row people;
begin
  -- The app's editor sends the id (rename, replace gifts); the assistant matches by name.
  if p ? 'id' then
    select * into v_row from people where id = (p->>'id')::uuid;
    if v_row.id is null then raise exception 'person_not_found'; end if;
  else
    select * into v_row from people where lower(name) = lower(trim(p->>'name')) limit 1;
  end if;
  if v_row.id is null then
    insert into people (name, birthday, notes, gift_ideas, contact_every_days)
    values (trim(p->>'name'), (p->>'birthday')::date, p->>'notes', coalesce(p->'gift_ideas', '[]'), (p->>'contact_every_days')::int)
    returning * into v_row;
  else
    update people set
      name = case when p ? 'id' then coalesce(nullif(trim(p->>'name'), ''), name) else name end,
      birthday = case when p ? 'birthday' then (p->>'birthday')::date else birthday end,
      notes = case when p ? 'notes' then p->>'notes' else notes end,
      gift_ideas = case when p ? 'id' and jsonb_typeof(p->'gift_ideas') = 'array' then p->'gift_ideas'
        when p ? 'gift_ideas' then (select coalesce(jsonb_agg(distinct g), '[]') from jsonb_array_elements(gift_ideas || (p->'gift_ideas')) g) else gift_ideas end,
      contact_every_days = case when p ? 'contact_every_days' then (p->>'contact_every_days')::int else contact_every_days end
    where id = v_row.id returning * into v_row;
  end if;
  perform sync_birthday_reminder(v_row.id);
  select * into v_row from people where id = v_row.id;
  return jsonb_build_object('action', 'saved', 'person', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_save_document(p jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row documents;
  v_tz text := ai_tz();
  v_at timestamptz;
  v_rem uuid;
  v_title text;
begin
  if p->>'file_path' is not null and split_part(p->>'file_path', '/', 1) <> auth.uid()::text then
    raise exception 'file_path_must_be_in_your_folder';
  end if;
  if p ? 'id' then
    select * into v_row from documents where id = (p->>'id')::uuid;
    if v_row.id is null then raise exception 'document_not_found'; end if;
  else
    select * into v_row from documents where lower(title) = lower(trim(p->>'title')) limit 1;
  end if;
  if v_row.id is null then
    insert into documents (title, category, notes, location_note, expires_at, file_path)
    values (trim(p->>'title'), p->>'category', p->>'notes', p->>'location_note', (p->>'expires_at')::date, p->>'file_path')
    returning * into v_row;
  else
    update documents set
      title = case when p ? 'id' then coalesce(nullif(trim(p->>'title'), ''), title) else title end,
      category = coalesce(p->>'category', category),
      notes = case when p ? 'notes' then p->>'notes' else notes end,
      location_note = case when p ? 'location_note' then p->>'location_note' else location_note end,
      expires_at = case when p ? 'expires_at' then (p->>'expires_at')::date else expires_at end,
      file_path = coalesce(p->>'file_path', file_path)
    where id = v_row.id returning * into v_row;
  end if;
  select id into v_rem from reminders where id = v_row.reminder_id;
  if v_row.expires_at is not null then
    v_title := v_row.title || ' expires ' || to_char(v_row.expires_at, 'Mon DD, YYYY');
    v_at := (greatest(v_row.expires_at - 30, (now() at time zone v_tz)::date)::timestamp + interval '9 hours') at time zone v_tz;
    if v_rem is null then
      v_rem := (ai_create_reminder(jsonb_build_object('title', v_title, 'remind_at', v_at, 'notes', v_row.location_note))->'reminder'->>'id')::uuid;
      update documents set reminder_id = v_rem where id = v_row.id;
    else
      update reminders set title = v_title, remind_at = v_at, completed_at = null, sync_status = 'pending_push', source_modified_at = now()
      where id = v_rem and (remind_at is distinct from v_at or title is distinct from v_title);
    end if;
  elsif v_rem is not null then
    perform ai_delete_reminder(v_rem);
    update documents set reminder_id = null where id = v_row.id;
  end if;
  select * into v_row from documents where id = v_row.id;
  return jsonb_build_object('action', 'saved', 'document', to_jsonb(v_row));
end;
$$;

-- ai_search_all: sort before the limit (newest matches were dropped), escape backslashes, and
-- return area_id for items/logs/reminders so the app can hide results from Face ID-locked areas.
create or replace function public.ai_search_all(p_query text, p_limit int default 30)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  q text := '%' || replace(replace(replace(trim(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%';
begin
  if length(trim(coalesce(p_query, ''))) < 2 then
    return '[]';
  end if;
  return coalesce((select jsonb_agg(x order by (x->>'date') desc nulls last) from (select x from (
    select jsonb_build_object('type', 'item', 'id', i.id, 'title', i.title, 'snippet', a.name, 'date', coalesce(i.completed_at, i.updated_at), 'area_id', i.area_id) x
      from items i join areas a on a.id = i.area_id where i.title ilike q or array_to_string(i.tags, ' ') ilike q
    union all
    select jsonb_build_object('type', 'log', 'id', l.id, 'title', l.note, 'snippet', a.name, 'date', l.logged_at, 'area_id', l.area_id)
      from logs l join areas a on a.id = l.area_id where l.note ilike q
    union all
    select jsonb_build_object('type', 'reminder', 'id', r.id, 'title', r.title, 'snippet', r.notes, 'date', r.remind_at, 'area_id', r.area_id)
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
    ) u order by (x->>'date') desc nulls last
    limit greatest(1, least(coalesce(p_limit, 30), 100))
  ) t), '[]');
end;
$$;
