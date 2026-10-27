-- Phase 12: body measurements tool (photos live in the private "photos" bucket under <user_id>/...).

create or replace function public.ai_log_measurement(p_type text, p_value double precision, p_unit text, p_recorded_at timestamptz default null, p_photo_path text default null)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_row body_measurements;
begin
  if p_photo_path is not null and split_part(p_photo_path, '/', 1) <> auth.uid()::text then
    raise exception 'photo_path_must_be_in_your_folder';
  end if;
  insert into body_measurements (type, value, unit, recorded_at, photo_path)
  values (lower(trim(p_type)), p_value, p_unit, coalesce(p_recorded_at, now()), p_photo_path)
  returning * into v_row;
  return jsonb_build_object('action', 'recorded', 'measurement', to_jsonb(v_row));
end;
$$;

revoke all on function public.ai_log_measurement(text, double precision, text, timestamptz, text) from public, anon;
grant execute on function public.ai_log_measurement(text, double precision, text, timestamptz, text) to authenticated;
