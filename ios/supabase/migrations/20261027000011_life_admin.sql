-- Phase 15: life admin. People (birthdays, last contact, gift ideas, reach-out nudges), documents with
-- expiry reminders, shopping lists (items with data.list) and travel (trips with packing lists as milestones).

alter table public.people add column if not exists contact_every_days integer check (contact_every_days is null or contact_every_days > 0);
alter table public.people add column if not exists reminder_id uuid;
alter table public.documents add column if not exists reminder_id uuid;

-- Next occurrence of a birthday on or after p_today (Feb 29 → Feb 28 in non-leap years).
create or replace function public.next_birthday(p_birthday date, p_today date)
returns date
language plpgsql
immutable
as $$
declare
  v_year int := extract(year from p_today)::int;
  v date;
begin
  if p_birthday is null then return null; end if;
  for i in 0..1 loop
    begin
      v := make_date(v_year + i, extract(month from p_birthday)::int, extract(day from p_birthday)::int);
    exception when others then
      v := make_date(v_year + i, 2, 28);
    end;
    if v >= p_today then return v; end if;
  end loop;
  return v;
end;
$$;

-- One yearly birthday reminder per person (the day before, 09:00, your default notify mode).
create or replace function public.sync_birthday_reminder(p_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_p people;
  v_tz text := ai_tz();
  v_next date;
  v_at timestamptz;
  v_rem uuid;
  v_title text;
begin
  select * into v_p from people where id = p_id;
  if v_p.id is null then return; end if;
  select id into v_rem from reminders where id = v_p.reminder_id;
  if v_p.birthday is null then
    if v_rem is not null then perform ai_delete_reminder(v_rem); update people set reminder_id = null where id = p_id; end if;
    return;
  end if;
  v_title := v_p.name || '''s birthday tomorrow';
  v_next := next_birthday(v_p.birthday, (now() at time zone v_tz)::date + 1);
  v_at := ((v_next - 1)::timestamp + interval '9 hours') at time zone v_tz;
  if v_rem is null then
    v_rem := (ai_create_reminder(jsonb_build_object('title', v_title, 'remind_at', v_at, 'repeat', 'FREQ=YEARLY'))->'reminder'->>'id')::uuid;
    update people set reminder_id = v_rem where id = p_id;
  else
    update reminders set title = v_title, remind_at = v_at, repeat_rule = 'FREQ=YEARLY',
      completed_at = null, sync_status = 'pending_push', source_modified_at = now()
    where id = v_rem and (remind_at is distinct from v_at or title is distinct from v_title);
  end if;
end;
$$;

-- add_person: upsert by name (case-insensitive). gift_ideas is a list of strings (merged, no duplicates).
create or replace function public.ai_add_person(p jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row people;
begin
  select * into v_row from people where lower(name) = lower(trim(p->>'name')) limit 1;
  if v_row.id is null then
    insert into people (name, birthday, notes, gift_ideas, contact_every_days)
    values (trim(p->>'name'), (p->>'birthday')::date, p->>'notes', coalesce(p->'gift_ideas', '[]'), (p->>'contact_every_days')::int)
    returning * into v_row;
  else
    update people set
      birthday = case when p ? 'birthday' then (p->>'birthday')::date else birthday end,
      notes = case when p ? 'notes' then p->>'notes' else notes end,
      gift_ideas = case when p ? 'gift_ideas' then (select coalesce(jsonb_agg(distinct g), '[]') from jsonb_array_elements(gift_ideas || (p->'gift_ideas')) g) else gift_ideas end,
      contact_every_days = case when p ? 'contact_every_days' then (p->>'contact_every_days')::int else contact_every_days end
    where id = v_row.id returning * into v_row;
  end if;
  perform sync_birthday_reminder(v_row.id);
  select * into v_row from people where id = v_row.id;
  return jsonb_build_object('action', 'saved', 'person', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_log_contact(p_person text, p_note text default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row people;
begin
  update people set last_contacted = now(),
    notes = case when p_note is null then notes else concat_ws(E'\n', notes, to_char(now(), 'YYYY-MM-DD') || ': ' || p_note) end
  where id::text = p_person or lower(name) = lower(trim(p_person))
  returning * into v_row;
  if v_row.id is null then raise exception 'person_not_found: %', p_person; end if;
  return jsonb_build_object('action', 'logged', 'person', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_upcoming_birthdays(p_days int default 30)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(jsonb_agg(x order by (x->>'next')::date), '[]') from (
    select jsonb_build_object('id', id, 'name', name, 'next', nb, 'turns',
                              case when extract(year from birthday) > 1900 then extract(year from nb)::int - extract(year from birthday)::int end,
                              'gift_ideas', gift_ideas) x
    from (select *, next_birthday(birthday, (now() at time zone ai_tz())::date) nb from people where birthday is not null) p
    where nb <= (now() at time zone ai_tz())::date + greatest(1, least(coalesce(p_days, 30), 366))
  ) t;
$$;

-- save_document: upsert by title; a reminder 30 days before it expires (or today if that's later).
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
  select * into v_row from documents where lower(title) = lower(trim(p->>'title')) limit 1;
  if v_row.id is null then
    insert into documents (title, category, notes, location_note, expires_at, file_path)
    values (trim(p->>'title'), p->>'category', p->>'notes', p->>'location_note', (p->>'expires_at')::date, p->>'file_path')
    returning * into v_row;
  else
    update documents set
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

-- Deleting a person or document also removes its reminder.
create or replace function public.ai_delete_person(p_id uuid)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare v_row people;
begin
  delete from people where id = p_id returning * into v_row;
  if v_row.id is null then raise exception 'person_not_found: %', p_id; end if;
  if v_row.reminder_id is not null then perform ai_delete_reminder(v_row.reminder_id); end if;
  return jsonb_build_object('action', 'deleted', 'name', v_row.name);
end;
$$;

create or replace function public.ai_delete_document(p_id uuid)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare v_row documents;
begin
  delete from documents where id = p_id returning * into v_row;
  if v_row.id is null then raise exception 'document_not_found: %', p_id; end if;
  if v_row.reminder_id is not null then perform ai_delete_reminder(v_row.reminder_id); end if;
  return jsonb_build_object('action', 'deleted', 'title', v_row.title, 'file_path', v_row.file_path);
end;
$$;

-- Nudges now include people you want to keep in touch with (redefined from migration 10).
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
  -- People you want to stay in touch with (people.contact_every_days).
  for r in
    select name, extract(day from now() - last_contacted)::int as days from people
    where contact_every_days is not null and (last_contacted is null or last_contacted < now() - make_interval(days => contact_every_days))
    order by last_contacted nulls first limit 2
  loop
    v_out := v_out || jsonb_build_object('kind', 'person', 'text',
      case when r.days is null then format('Reach out to %s.', r.name) else format('Reach out to %s (last contact %s days ago).', r.name, r.days) end);
  end loop;
  return v_out;
end;
$$;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('sync_birthday_reminder', 'ai_add_person', 'ai_log_contact', 'ai_upcoming_birthdays',
                                                       'ai_save_document', 'ai_delete_person', 'ai_delete_document')
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
