-- Run only in the disposable PostgreSQL verification cluster.
begin;

set local role h1_auth_admin;
insert into auth.users values
  ('00000000-0000-0000-0000-000000000007', '{"full_name":"Synthetic dose owner"}'),
  ('00000000-0000-0000-0000-000000000008', '{"full_name":"Synthetic second owner"}');
reset role;

set local role h1_migration_owner;
insert into public.medications (id, user_id, name, times, prescription_plan) values
  ('00000000-0000-0000-0000-000000000107', '00000000-0000-0000-0000-000000000007',
    'Synthetic daily', '{08:00,21:00}', null),
  ('00000000-0000-0000-0000-000000000207', '00000000-0000-0000-0000-000000000007',
    'Synthetic interval', '{}', '{"kind":"interval","interval_minutes":60,"first_dose_at":"2026-11-01T01:30:00-04:00"}'),
  ('00000000-0000-0000-0000-000000000108', '00000000-0000-0000-0000-000000000008',
    'Synthetic other medication', '{21:00}', null);
reset role;

set local role authenticated;
do $$
declare
  alice constant uuid := '00000000-0000-0000-0000-000000000007';
  bob constant uuid := '00000000-0000-0000-0000-000000000008';
  daily_med constant uuid := '00000000-0000-0000-0000-000000000107';
  interval_med constant uuid := '00000000-0000-0000-0000-000000000207';
  other_med constant uuid := '00000000-0000-0000-0000-000000000108';
  morning public.medication_logs%rowtype;
  evening public.medication_logs%rowtype;
  replacement uuid;
begin
  perform set_config('request.jwt.claim.sub', alice::text, true);

  insert into public.medication_logs (user_id, medication_id, taken_at)
  values (alice, daily_med, '2026-11-01 09:00:00+00'), (alice, daily_med, '2026-11-01 09:00:00+00');
  if (select count(*) from public.medication_logs where user_id = alice and occurrence_key is null) <> 2 then
    raise exception 'Legacy logs lost their null identity';
  end if;

  -- Selected local date comes from the slot, even when the action happens after midnight.
  insert into public.medication_logs (user_id, medication_id, scheduled_at, scheduled_local_at, taken_at)
  values (alice, daily_med, '2026-11-01 21:00:00-05', '2026-11-01 21:00', '2026-11-02 07:00:00+00')
  returning * into evening;
  if evening.scheduled_at <> '2026-11-02 02:00:00+00'::timestamptz
     or evening.taken_at <> '2026-11-02 07:00:00+00'::timestamptz
     or evening.occurrence_key <> 'daily:1793566800000000' then
    raise exception 'Incorrect stored date, actual logging time, or occurrence key';
  end if;

  insert into public.medication_logs (user_id, medication_id, scheduled_at, scheduled_local_at)
  values (alice, daily_med, '2026-11-01 21:00:00+05:30', '2026-11-01 21:00')
  on conflict (user_id, medication_id, occurrence_key) do nothing;
  if found then raise exception 'Timezone-change retry duplicated the same daily slot'; end if;
  if not exists (select from public.medication_logs where id = evening.id and taken_at = evening.taken_at
                 and scheduled_at = evening.scheduled_at) then
    raise exception 'Retry rewrote the original log';
  end if;
  insert into public.medication_logs (user_id, medication_id, scheduled_at, scheduled_local_at)
  values (alice, daily_med, '2026-11-01 08:00:00-05', '2026-11-01 08:00')
  returning * into morning;
  insert into public.medication_logs (user_id, medication_id, scheduled_at, scheduled_local_at)
  values (alice, daily_med, '2026-11-02 21:00:00-05', '2026-11-02 21:00');

  insert into public.medication_logs (user_id, medication_id, scheduled_at)
  values (alice, interval_med, '2026-11-01 01:30:00-04'), (alice, interval_med, '2026-11-01 01:30:00-05');
  insert into public.medication_logs (user_id, medication_id, scheduled_at)
  values (alice, interval_med, '2026-11-01 05:30:00+00')
  on conflict (user_id, medication_id, occurrence_key) do nothing;
  if found or (select count(*) from public.medication_logs where medication_id = interval_med) <> 2 then
    raise exception 'Interval identity split the same instant or combined repeated clock times';
  end if;
  begin
    insert into public.medication_logs (user_id, medication_id, scheduled_at)
    values (alice, interval_med, '2026-11-01 05:30:00+00');
    raise exception 'Plain insert allowed a duplicate occurrence';
  exception when unique_violation then null;
  end;
  begin
    insert into public.medication_logs (user_id, medication_id, scheduled_local_at)
    values (alice, daily_med, '2026-11-01 12:00');
    raise exception 'Daily row accepted a missing scheduled instant';
  exception when check_violation then null;
  end;

  perform set_config('request.jwt.claim.sub', bob::text, true);
  if exists (select from public.medication_logs where id = evening.id) then
    raise exception 'Other account read the log';
  end if;
  delete from public.medication_logs
  where user_id = alice and medication_id = daily_med and occurrence_key = evening.occurrence_key and id = evening.id;
  if found then raise exception 'Other account undid the log'; end if;
  begin
    insert into public.medication_logs (user_id, medication_id, scheduled_at)
    values (alice, daily_med, evening.scheduled_at);
    raise exception 'Other account used the owner ID';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.medication_logs (user_id, medication_id, scheduled_at)
    values (bob, daily_med, evening.scheduled_at)
    on conflict (user_id, medication_id, occurrence_key) do nothing;
    raise exception 'Other account used its own ID with a foreign medication';
  exception when foreign_key_violation then null;
  end;
  insert into public.medication_logs (user_id, medication_id, scheduled_at, scheduled_local_at)
  values (bob, other_med, evening.scheduled_at, evening.scheduled_local_at);

  perform set_config('request.jwt.claim.sub', alice::text, true);
  delete from public.medication_logs
  where user_id = alice and medication_id = daily_med and occurrence_key = morning.occurrence_key and id = evening.id;
  if found then raise exception 'Undo matched the wrong occurrence'; end if;
  delete from public.medication_logs
  where user_id = alice and medication_id = daily_med and occurrence_key = evening.occurrence_key and id = evening.id;
  if not found or not exists (select from public.medication_logs where id = morning.id)
     or (select count(*) from public.medication_logs where user_id = alice and occurrence_key is null) <> 2 then
    raise exception 'Undo did not preserve the other dose and legacy logs';
  end if;
  insert into public.medication_logs (user_id, medication_id, scheduled_at, scheduled_local_at)
  values (alice, daily_med, evening.scheduled_at, evening.scheduled_local_at)
  returning id into replacement;
  delete from public.medication_logs
  where user_id = alice and medication_id = daily_med and occurrence_key = evening.occurrence_key and id = evening.id;
  if found or replacement = evening.id or not exists (select from public.medication_logs where id = replacement) then
    raise exception 'Stale Undo deleted a replacement log';
  end if;

  perform set_config('request.jwt.claim.sub', bob::text, true);
  if not exists (select from public.medication_logs where medication_id = other_med and occurrence_key = evening.occurrence_key) then
    raise exception 'Owner Undo affected the other account';
  end if;
end
$$;
rollback;
