begin;

create table public.daily_report_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  time_zone text not null,
  next_date date not null,
  due_at timestamptz not null
);
create index nova_daily_report_due on public.daily_report_settings (due_at, user_id);

create table public.daily_report_snapshots (
  user_id uuid not null references public.daily_report_settings(user_id) on delete cascade,
  local_date date not null,
  time_zone text not null,
  generated_at timestamptz not null,
  observations jsonb not null,
  notice_claimed_at timestamptz,
  primary key (user_id, local_date)
);
create index nova_daily_report_retention on public.daily_report_snapshots (generated_at);

alter table public.daily_report_settings enable row level security;
alter table public.daily_report_snapshots enable row level security;
revoke all on public.daily_report_settings, public.daily_report_snapshots from public, anon, authenticated;
grant select on public.daily_report_settings, public.daily_report_snapshots to authenticated;
create policy nova_daily_report_settings_owner on public.daily_report_settings
  as restrictive for select to public using ((select auth.uid()) = user_id);
create policy nova_daily_report_snapshot_owner on public.daily_report_snapshots
  as restrictive for select to public using ((select auth.uid()) = user_id);
create policy nova_daily_report_settings_read on public.daily_report_settings
  for select to authenticated using (true);
create policy nova_daily_report_snapshot_read on public.daily_report_snapshots
  for select to authenticated using (true);

create function public.set_daily_report_schedule(expected_account uuid, enabled boolean, zone_name text)
returns void language plpgsql security definer set search_path = pg_catalog
as $$
declare
  account_id uuid := auth.uid();
  first_day date;
begin
  if account_id is null or account_id is distinct from expected_account then
    raise insufficient_privilege using message = 'Use the account that opened report settings';
  end if;
  if enabled is false then
    delete from public.daily_report_settings where user_id = account_id;
    return;
  end if;
  if enabled is null or zone_name is null or length(zone_name) > 100
     or zone_name like 'posix/%' or zone_name like 'right/%'
     or not exists (select from pg_timezone_names where name = zone_name) then
    raise invalid_parameter_value using message = 'Unsupported report time zone';
  end if;
  first_day := (statement_timestamp() at time zone zone_name)::date;
  insert into public.daily_report_settings as settings (user_id, time_zone, next_date, due_at)
  values (account_id, zone_name, first_day, (first_day + 1 + time '08:00') at time zone zone_name)
  on conflict (user_id) do update
    set time_zone = excluded.time_zone, next_date = excluded.next_date, due_at = excluded.due_at
    where settings.time_zone <> excluded.time_zone;
end
$$;

-- Only the trusted database scheduler can call this function. It runs with its caller's
-- database privileges. Every source query is scoped to the locked, opted-in account.
create function public.generate_due_daily_reports(run_at timestamptz default statement_timestamp())
returns jsonb language plpgsql set search_path = pg_catalog
as $$
declare
  job public.daily_report_settings%rowtype;
  report_date date;
  local_today date;
  opens timestamptz;
  closes timestamptz;
  saved_count integer := 0;
  failed_count integer := 0;
  affected integer;
begin
  for job in
    select * from public.daily_report_settings
    where due_at <= run_at order by due_at, user_id limit 100
    for update skip locked
  loop
    begin
      local_today := (run_at at time zone job.time_zone)::date;
      report_date := greatest(job.next_date, local_today - 7);
      opens := report_date::timestamp at time zone job.time_zone;
      closes := (report_date + 1)::timestamp at time zone job.time_zone;

      if report_date < local_today
         and (report_date + 1 + time '08:00') at time zone job.time_zone <= run_at then
        if opens < closes then
          insert into public.daily_report_snapshots (user_id, local_date, time_zone, generated_at, observations)
          with water as (
            select case when bool_and(amount_ml >= 0) then sum(amount_ml) end as total
            from public.water_logs where user_id = job.user_id and logged_at >= opens and logged_at < closes
          ), latest_sleep as (
            select hours from public.sleep_logs
            where user_id = job.user_id and logged_at >= opens and logged_at < closes
              and logged_at = (select max(logged_at) from public.sleep_logs
                where user_id = job.user_id and logged_at >= opens and logged_at < closes)
          ), sleep as (
            select count(*) = 0 as absent,
              case when count(*) = count(hours) and count(distinct hours) = 1
                and min(hours) between 0 and 24 then min(hours) end as hours
            from latest_sleep
          ), meals as (
            select nullif(count(*), 0) as total,
              case when count(*) = count(calories) and bool_and(calories between 0 and 5000)
                then sum(calories) end as kcal
            from public.meal_logs where user_id = job.user_id and status = 'confirmed'
              and logged_at >= opens and logged_at < closes
          ), doses as (
            select nullif(count(*), 0) as total
            from public.medication_logs as log
            join public.medications as med on med.id = log.medication_id and med.user_id = job.user_id
            where log.user_id = job.user_id and med.status in ('confirmed', 'ended')
              and log.status = 'taken' and log.occurrence_key is not null
              and ((log.scheduled_local_at >= report_date and log.scheduled_local_at < report_date + 1)
                or (log.scheduled_local_at is null and log.scheduled_at >= opens and log.scheduled_at < closes))
          ), symptom_counts as (
            select nullif(count(*), 0) as total from public.symptom_logs
            where user_id = job.user_id and status in ('active', 'resolved') and started_at >= opens and started_at < closes
          )
          select job.user_id, report_date, job.time_zone, run_at, jsonb_build_object(
            'water_ml', water.total, 'water_goal_ml', profile.water_goal_ml,
            'sleep_hours', coalesce(sleep.hours, imported_sleep.value / 3600.0),
            'sleep_source', case when sleep.hours is not null then 'manual' else imported_sleep.source end,
            'sleep_goal_hours', profile.sleep_goal_hours, 'steps', steps.value, 'steps_source', steps.source,
            'meal_count', meals.total, 'calories', meals.kcal, 'dose_confirmations', doses.total,
            'symptom_onsets', symptom_counts.total
          )
          from water cross join sleep cross join meals cross join doses cross join symptom_counts
          join public.profiles as profile on profile.id = job.user_id
          left join public.wearable_daily_totals as steps on steps.user_id = job.user_id
            and steps.local_date = report_date and steps.metric = 'steps'
            and steps.window_start = opens and steps.window_end = closes and steps.captured_at between closes and run_at
          left join public.wearable_daily_totals as imported_sleep on sleep.absent and imported_sleep.user_id = job.user_id
            and imported_sleep.local_date = report_date and imported_sleep.metric = 'sleep'
            and imported_sleep.window_start = opens and imported_sleep.window_end = closes
            and imported_sleep.captured_at between closes and run_at
          on conflict (user_id, local_date) do nothing;
          get diagnostics affected = row_count;
          saved_count := saved_count + affected;
        end if;
        report_date := report_date + 1;
      end if;
      update public.daily_report_settings set next_date = report_date,
        due_at = (report_date + 1 + time '08:00') at time zone job.time_zone where user_id = job.user_id;
    exception when others then
      failed_count := failed_count + 1;
      update public.daily_report_settings set due_at = run_at + interval '15 minutes' where user_id = job.user_id;
    end;
  end loop;
  delete from public.daily_report_snapshots where generated_at < run_at - interval '30 days';
  if failed_count > 0 then
    raise warning 'Daily report generation deferred for % job(s)', failed_count;
  end if;
  return jsonb_build_object('generated', saved_count, 'failed', failed_count);
end
$$;

create function public.claim_daily_report_notice(expected_account uuid)
returns boolean language plpgsql security definer set search_path = pg_catalog
as $$
declare
  account_id uuid := auth.uid();
  report_zone text;
  local_yesterday date;
begin
  if account_id is null or account_id is distinct from expected_account then
    raise insufficient_privilege using message = 'Use the account that opened daily reports';
  end if;
  select time_zone into report_zone from public.daily_report_settings where user_id = account_id for update;
  if not found then return false; end if;
  local_yesterday := (statement_timestamp() at time zone report_zone)::date - 1;
  update public.daily_report_snapshots set notice_claimed_at = statement_timestamp()
    where user_id = account_id and local_date = local_yesterday and notice_claimed_at is null;
  return found;
end
$$;

revoke all on function public.generate_due_daily_reports(timestamptz) from public, anon, authenticated;
revoke all on function public.set_daily_report_schedule(uuid, boolean, text),
  public.claim_daily_report_notice(uuid) from public, anon, authenticated;
grant execute on function public.set_daily_report_schedule(uuid, boolean, text),
  public.claim_daily_report_notice(uuid) to authenticated;

commit;
