-- Disposable PostgreSQL only.
begin;
insert into auth.users (id, raw_user_meta_data) values
 ('a1600000-0000-0000-0000-000000000001', '{"full_name":"Synthetic report owner"}'),
 ('a1600000-0000-0000-0000-000000000002', '{"full_name":"Synthetic empty account"}'),
 ('a1600000-0000-0000-0000-000000000003', '{"full_name":"Synthetic disabled account"}');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1600000-0000-0000-0000-000000000001', true);
do $$
begin
  perform public.set_daily_report_schedule(auth.uid(), true, 'America/New_York');
  if (select time_zone from public.daily_report_settings) <> 'America/New_York'
    then raise exception 'Schedule opt-in not saved'; end if;
  begin
    perform public.set_daily_report_schedule(auth.uid(), true, 'INVALID/ZONE');
    raise exception 'Invalid zone accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.set_daily_report_schedule('a1600000-0000-0000-0000-000000000002', true, 'UTC');
    raise exception 'Cross-account schedule accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.generate_due_daily_reports();
    raise exception 'Client can run scheduler';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.daily_report_settings set due_at = now();
    raise exception 'Client can edit scheduler cursor';
  exception when insufficient_privilege then null;
  end;
end
$$;
reset role;

update public.daily_report_settings set next_date = '2026-03-08', due_at = '2026-03-09T12:00:00Z';
insert into public.daily_report_settings values
 ('a1600000-0000-0000-0000-000000000002', 'UTC', '2026-03-08', '2026-03-09T08:00:00Z');
update public.profiles set water_goal_ml = 850, sleep_goal_hours = 7.5
 where id = 'a1600000-0000-0000-0000-000000000001';
insert into public.water_logs (user_id, amount_ml, logged_at) values
 ('a1600000-0000-0000-0000-000000000001', 9000, '2026-03-08T04:59:59Z'),
 ('a1600000-0000-0000-0000-000000000001', 125, '2026-03-08T05:00:00Z'),
 ('a1600000-0000-0000-0000-000000000001', 200, '2026-03-09T03:59:59Z'),
 ('a1600000-0000-0000-0000-000000000001', 9000, '2026-03-09T04:00:00Z'),
 ('a1600000-0000-0000-0000-000000000003', 5500, '2026-03-08T13:00:00Z');
insert into public.sleep_logs (user_id, hours, logged_at) values
 ('a1600000-0000-0000-0000-000000000001', 3, '2026-03-08T12:00:00Z'),
 ('a1600000-0000-0000-0000-000000000001', 8, '2026-03-08T15:00:00Z'),
 ('a1600000-0000-0000-0000-000000000001', 9, '2026-03-08T15:00:00Z');
insert into public.meal_logs (user_id, description, status, calories, logged_at) values
 ('a1600000-0000-0000-0000-000000000001', 'Synthetic confirmed', 'confirmed', 240, '2026-03-08T13:00:00Z'),
 ('a1600000-0000-0000-0000-000000000001', 'Synthetic incomplete', 'confirmed', null, '2026-03-08T14:00:00Z'),
 ('a1600000-0000-0000-0000-000000000001', 'Synthetic draft', 'pending', 500, '2026-03-08T13:00:00Z');
insert into public.wearable_daily_totals values
 ('a1600000-0000-0000-0000-000000000001', 'steps', '2026-03-08', '2026-03-08T05:00:00Z',
  '2026-03-09T04:00:00Z', '2026-03-09T03:00:00Z', 'health_connect', 1234),
 ('a1600000-0000-0000-0000-000000000001', 'sleep', '2026-03-08', '2026-03-08T05:00:00Z',
  '2026-03-09T04:00:00Z', '2026-03-09T10:00:00Z', 'apple_health', 24000);

-- A scoped synthetic trigger makes the first write fail without changing source data.
create function public.nova_test_fail_report() returns trigger language plpgsql as $$
begin
  if new.user_id = 'a1600000-0000-0000-0000-000000000001'
    then raise exception 'Synthetic transient report failure'; end if;
  return new;
end
$$;
create trigger nova_test_fail_report before insert on public.daily_report_snapshots
for each row execute function public.nova_test_fail_report();
set local role h1_migration_owner;
do $$
begin
  if public.generate_due_daily_reports('2026-03-09T11:59:00Z') <> '{"generated":1,"failed":0}'::jsonb
    then raise exception 'Wrong local due boundaries'; end if;
  if public.generate_due_daily_reports('2026-03-09T12:00:00Z') <> '{"generated":0,"failed":1}'::jsonb
    then raise exception 'Failure was not retriable'; end if;
end
$$;
reset role;
drop trigger nova_test_fail_report on public.daily_report_snapshots;
set local role h1_migration_owner;
do $$
declare summary jsonb;
begin
  if public.generate_due_daily_reports('2026-03-09T12:14:59Z') <> '{"generated":0,"failed":0}'::jsonb
    then raise exception 'Retry backoff bypassed'; end if;
  if public.generate_due_daily_reports('2026-03-09T12:15:00Z') <> '{"generated":1,"failed":0}'::jsonb
    then raise exception 'Retry did not generate exactly one report'; end if;
  if public.generate_due_daily_reports('2026-03-09T12:16:00Z') <> '{"generated":0,"failed":0}'::jsonb
    then raise exception 'Repeated tick duplicated the report'; end if;
  select observations into strict summary from public.daily_report_snapshots
    where user_id = 'a1600000-0000-0000-0000-000000000001';
  if not summary @> '{"water_ml":325,"water_goal_ml":850,"sleep_hours":null,"sleep_goal_hours":7.5,
                       "steps":null,"meal_count":2,"calories":null}'::jsonb
    then raise exception 'Incorrect DST, confirmed-only or partial results: %', summary; end if;
  select observations into strict summary from public.daily_report_snapshots
    where user_id = 'a1600000-0000-0000-0000-000000000002';
  if not summary @> '{"water_ml":null,"sleep_hours":null,"steps":null,"meal_count":null,"calories":null}'::jsonb
    then raise exception 'Missing data became a measurement'; end if;
  if exists (select from public.daily_report_snapshots where user_id = 'a1600000-0000-0000-0000-000000000003')
    then raise exception 'Opted-out account was processed'; end if;
  if public.generate_due_daily_reports('2026-05-04T15:00:00Z') <> '{"generated":2,"failed":0}'::jsonb
    then raise exception 'Missed job did not catch up'; end if;
  if exists (select from public.daily_report_snapshots where local_date <> '2026-04-27')
    then raise exception 'Catch-up or retention is unbounded'; end if;
end
$$;
reset role;

insert into public.daily_report_snapshots (user_id, local_date, time_zone, generated_at, observations)
values ('a1600000-0000-0000-0000-000000000001',
        (now() at time zone 'America/New_York')::date - 1, 'America/New_York', now(), '{}');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1600000-0000-0000-0000-000000000001', true);
do $$
begin
  if not public.claim_daily_report_notice(auth.uid()) then raise exception 'Notification was not claimed'; end if;
  if public.claim_daily_report_notice(auth.uid()) then raise exception 'Duplicate notification claim'; end if;
  perform public.set_daily_report_schedule(auth.uid(), true, 'Asia/Colombo');
  if (select time_zone from public.daily_report_settings) <> 'Asia/Colombo'
    or (select next_date from public.daily_report_settings) <> (now() at time zone 'Asia/Colombo')::date
    then raise exception 'Time-zone change did not reset future dates'; end if;
  if not exists (select from public.daily_report_snapshots where time_zone = 'America/New_York')
    then raise exception 'Historical snapshot was rebucketed'; end if;
  perform public.set_daily_report_schedule(auth.uid(), false, null);
  if exists (select from public.daily_report_settings) or exists (select from public.daily_report_snapshots)
    or public.claim_daily_report_notice(auth.uid()) then raise exception 'Opt-out did not clear reports'; end if;
end
$$;
select set_config('request.jwt.claim.sub', 'a1600000-0000-0000-0000-000000000003', true);
do $$
begin
  if exists (select from public.daily_report_settings) or exists (select from public.daily_report_snapshots)
    then raise exception 'Cross-account report rows visible'; end if;
end
$$;
set local role anon;
do $$
begin
  begin
    perform public.claim_daily_report_notice(auth.uid());
    raise exception 'Anonymous claim accepted';
  exception when insufficient_privilege then null;
  end;
end
$$;
rollback;
