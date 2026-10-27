-- Phase 13: money. Expenses are metrics named "expense" (category in data); budgets live in the finance
-- area's config: {"currency": "EUR", "monthly_budget": 2000, "budgets": {"food": 400, "transport": 120}}.
-- Subscriptions get a renewal reminder through the normal reminders system.

alter table public.subscriptions add column if not exists reminder_id uuid;
alter table public.subscriptions add column if not exists notes text;

-- The finance area (first of kind "finance"), created as "Money" if missing.
create or replace function public.ai_finance_area()
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid;
begin
  select id into v_id from areas where kind = 'finance' order by sort_order, created_at limit 1;
  if v_id is null then
    v_id := (ai_create_area('Money', 'finance', 'creditcard', '#F2A93B')->'area'->>'id')::uuid;
  end if;
  return v_id;
end;
$$;

create or replace function public.ai_log_expense(p_amount numeric, p_category text, p_note text default null, p_spent_at timestamptz default null, p_currency text default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_area uuid := ai_finance_area();
  v_currency text;
  v_row metrics;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount_must_be_positive';
  end if;
  select coalesce(p_currency, config->>'currency', 'USD') into v_currency from areas where id = v_area;
  insert into metrics (area_id, name, value, unit, recorded_at, data, source)
  values (v_area, 'expense', p_amount, upper(v_currency), coalesce(p_spent_at, now()),
          jsonb_build_object('category', lower(trim(coalesce(p_category, 'other'))), 'note', p_note), 'ai')
  returning * into v_row;
  return jsonb_build_object('action', 'recorded', 'metric', to_jsonb(v_row));
end;
$$;

-- get_budget_status: spending per category vs budget for a month (default: this month, user's timezone).
create or replace function public.ai_budget_status(p_month date default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_tz text := ai_tz();
  v_area areas;
  v_month date := date_trunc('month', coalesce(p_month, (now() at time zone v_tz)::date))::date;
  v_from timestamptz := v_month::timestamp at time zone v_tz;
  v_to timestamptz := (v_month + interval '1 month')::timestamp at time zone v_tz;
  v_today date := (now() at time zone v_tz)::date;
begin
  select * into v_area from areas where kind = 'finance' order by sort_order, created_at limit 1;
  if v_area.id is null then
    return jsonb_build_object('month', v_month, 'spent', 0, 'categories', '[]'::jsonb, 'note', 'no finance area yet');
  end if;
  return jsonb_build_object(
    'month', v_month,
    'currency', coalesce(v_area.config->>'currency', 'USD'),
    'monthly_budget', (v_area.config->>'monthly_budget')::numeric,
    'spent', coalesce((select round(sum(value)::numeric, 2) from metrics where area_id = v_area.id and name = 'expense'
                       and recorded_at >= v_from and recorded_at < v_to), 0),
    'days_left', greatest(0, (v_month + interval '1 month')::date - greatest(v_today, v_month)),
    'subscriptions_monthly', coalesce((select round(sum(case billing_cycle when 'weekly' then amount * 52 / 12 when 'monthly' then amount
                                     when 'quarterly' then amount / 3 when 'yearly' then amount / 12 end)::numeric, 2) from subscriptions), 0),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('category', c.category, 'spent', c.spent, 'budget', c.budget,
                                          'left', case when c.budget is null then null else c.budget - c.spent end)
                       order by c.spent desc)
      from (
        select cat as category, coalesce(s.spent, 0) as spent, (v_area.config->'budgets'->>cat)::numeric as budget
        from (
          select distinct cat from (
            select data->>'category' as cat from metrics where area_id = v_area.id and name = 'expense' and recorded_at >= v_from and recorded_at < v_to
            union select jsonb_object_keys(coalesce(v_area.config->'budgets', '{}'))
          ) k where cat is not null
        ) cats
        left join (
          select data->>'category' as category, round(sum(value)::numeric, 2) spent
          from metrics where area_id = v_area.id and name = 'expense' and recorded_at >= v_from and recorded_at < v_to
          group by 1
        ) s on s.category = cats.cat
      ) c), '[]')
  );
end;
$$;

-- Next renewal date on or after today for a subscription's cycle.
create or replace function public.next_renewal(p_from date, p_cycle text, p_today date)
returns date
language plpgsql
immutable
as $$
declare
  v date := p_from;
  v_step interval := case p_cycle when 'weekly' then interval '1 week' when 'quarterly' then interval '3 months'
                                  when 'yearly' then interval '1 year' else interval '1 month' end;
begin
  if v is null then return null; end if;
  while v < p_today loop v := (v + v_step)::date; end loop;
  return v;
end;
$$;

-- Keeps one renewal reminder per subscription, 2 days before it renews (at 09:00 in the user's timezone).
create or replace function public.sync_subscription_reminder(p_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_sub subscriptions;
  v_tz text := ai_tz();
  v_at timestamptz;
  v_rem uuid;
begin
  select * into v_sub from subscriptions where id = p_id;
  if v_sub.id is null or v_sub.renews_on is null then return; end if;
  v_at := ((v_sub.renews_on - 2)::timestamp + interval '9 hours') at time zone v_tz;
  select id into v_rem from reminders where id = v_sub.reminder_id;
  if v_rem is null then
    v_rem := (ai_create_reminder(jsonb_build_object(
      'title', v_sub.name || ' renews on ' || to_char(v_sub.renews_on, 'Mon DD'),
      'remind_at', v_at, 'notes', v_sub.amount || ' ' || v_sub.currency || ' ' || v_sub.billing_cycle,
      'area', v_sub.area_id::text))->'reminder'->>'id')::uuid;
    update subscriptions set reminder_id = v_rem where id = p_id;
  else
    update reminders set title = v_sub.name || ' renews on ' || to_char(v_sub.renews_on, 'Mon DD'), remind_at = v_at,
      completed_at = null, sync_status = 'pending_push', source_modified_at = now()
    where id = v_rem and (remind_at is distinct from v_at or completed_at is not null);
  end if;
end;
$$;

create or replace function public.ai_upsert_subscription(p jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row subscriptions;
  v_today date := (now() at time zone ai_tz())::date;
begin
  select * into v_row from subscriptions where lower(name) = lower(trim(p->>'name')) limit 1;
  if v_row.id is null then
    insert into subscriptions (name, amount, currency, billing_cycle, renews_on, area_id, notes)
    values (trim(p->>'name'), (p->>'amount')::numeric,
            upper(coalesce(p->>'currency', (select config->>'currency' from areas where id = ai_finance_area()), 'USD')),
            coalesce(p->>'billing_cycle', 'monthly'), (p->>'renews_on')::date, ai_finance_area(), p->>'notes')
    returning * into v_row;
  else
    update subscriptions set
      amount = coalesce((p->>'amount')::numeric, amount),
      currency = coalesce(upper(p->>'currency'), currency),
      billing_cycle = coalesce(p->>'billing_cycle', billing_cycle),
      renews_on = coalesce((p->>'renews_on')::date, renews_on),
      notes = case when p ? 'notes' then p->>'notes' else notes end
    where id = v_row.id returning * into v_row;
  end if;
  update subscriptions set renews_on = next_renewal(renews_on, billing_cycle, v_today) where id = v_row.id returning * into v_row;
  perform sync_subscription_reminder(v_row.id);
  select * into v_row from subscriptions where id = v_row.id;
  return jsonb_build_object('action', 'saved', 'subscription', to_jsonb(v_row));
end;
$$;

create or replace function public.ai_delete_subscription(p_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row subscriptions;
begin
  delete from subscriptions where id = p_id returning * into v_row;
  if v_row.id is null then raise exception 'subscription_not_found: %', p_id; end if;
  if v_row.reminder_id is not null then perform ai_delete_reminder(v_row.reminder_id); end if;
  return jsonb_build_object('action', 'deleted', 'name', v_row.name);
end;
$$;

-- Call on launch: moves past renewals forward and refreshes their reminders.
create or replace function public.ai_roll_subscriptions()
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_today date := (now() at time zone ai_tz())::date;
  v_id uuid;
  v_n int := 0;
begin
  for v_id in select id from subscriptions where renews_on < v_today loop
    update subscriptions set renews_on = next_renewal(renews_on, billing_cycle, v_today) where id = v_id;
    perform sync_subscription_reminder(v_id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace function public.ai_list_subscriptions()
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'amount', amount, 'currency', currency,
                                               'billing_cycle', billing_cycle, 'renews_on', renews_on) order by renews_on nulls last), '[]')
  from subscriptions;
$$;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('ai_finance_area', 'ai_log_expense', 'ai_budget_status', 'sync_subscription_reminder',
                                                       'ai_upsert_subscription', 'ai_delete_subscription', 'ai_roll_subscriptions', 'ai_list_subscriptions')
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
