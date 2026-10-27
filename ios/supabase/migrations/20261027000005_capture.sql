-- Phase 8: quick capture. The agent routes a capture into items / reminders / logs / metrics; the
-- Edge Function records what it created in captures.data.created so the app can undo it.

-- Undo a routed capture: delete what routing created and put the capture back in the inbox.
-- Reminders already in Apple Reminders are marked pending_delete (the device removes them).
create or replace function public.ai_undo_capture(p_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_cap captures;
  v_entry jsonb;
  v_table text;
  v_row uuid;
  v_undone integer := 0;
begin
  select * into v_cap from captures where id = p_id;
  if v_cap.id is null then
    raise exception 'capture_not_found: %', p_id;
  end if;

  for v_entry in select * from jsonb_array_elements(coalesce(v_cap.data->'created', '[]'))
  loop
    v_table := v_entry->>'table';
    v_row := (v_entry->>'id')::uuid;
    if v_table = 'items' then
      delete from items where id = v_row;
    elsif v_table = 'logs' then
      delete from logs where id = v_row;
    elsif v_table = 'metrics' then
      delete from metrics where id = v_row;
    elsif v_table = 'reminders' then
      update reminders set sync_status = 'pending_delete', source_modified_at = now()
      where id = v_row and apple_reminder_id is not null;
      delete from reminders where id = v_row and apple_reminder_id is null;
    elsif v_table = 'areas' then
      -- Only remove an area routing created if nothing else was added to it since.
      delete from areas a where a.id = v_row
        and not exists (select 1 from items i where i.area_id = a.id)
        and not exists (select 1 from logs l where l.area_id = a.id)
        and not exists (select 1 from metrics m where m.area_id = a.id);
    else
      continue;
    end if;
    v_undone := v_undone + 1;
  end loop;

  update captures
  set status = 'inbox', routed_area_id = null, routed_item_id = null,
      data = (data - 'created') || jsonb_build_object('undone_at', now())
  where id = p_id;

  return jsonb_build_object('action', 'undone', 'undone', v_undone);
end;
$$;

-- capture tool: park a thought in the inbox to sort later.
create or replace function public.ai_capture(p_text text, p_source text default 'text')
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row captures;
begin
  insert into captures (raw_text, source) values (trim(p_text), coalesce(p_source, 'text')) returning * into v_row;
  return jsonb_build_object('action', 'captured', 'capture', to_jsonb(v_row));
end;
$$;

revoke all on function public.ai_undo_capture(uuid) from public, anon;
revoke all on function public.ai_capture(text, text) from public, anon;
grant execute on function public.ai_undo_capture(uuid) to authenticated;
grant execute on function public.ai_capture(text, text) to authenticated;
