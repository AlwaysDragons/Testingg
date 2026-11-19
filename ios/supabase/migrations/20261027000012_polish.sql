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
