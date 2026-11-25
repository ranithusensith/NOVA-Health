-- Daily wearable aggregates only. Heart-rate samples retain their existing table and key.
begin;

create table public.wearable_daily_totals (
  user_id uuid not null references public.profiles(id) on delete cascade,
  metric text not null check (metric in ('steps', 'sleep')),
  local_date date not null,
  window_start timestamptz not null,
  window_end timestamptz not null,
  captured_at timestamptz not null,
  source text not null check (source in ('apple_health', 'health_connect')),
  value integer not null check (
    (metric = 'steps' and value between 0 and 1000000)
    or (metric = 'sleep' and value between 1 and 86400)
  ),
  primary key (user_id, metric, local_date, window_start, window_end),
  check (isfinite(local_date) and isfinite(window_start) and isfinite(window_end) and isfinite(captured_at)),
  check (window_end - window_start between interval '21 hours' and interval '27 hours'),
  check (window_start between (local_date::timestamp at time zone 'UTC') - interval '14 hours'
                          and (local_date::timestamp at time zone 'UTC') + interval '14 hours'),
  check (window_end between ((local_date + 1)::timestamp at time zone 'UTC') - interval '14 hours'
                        and ((local_date + 1)::timestamp at time zone 'UTC') + interval '14 hours'),
  check (captured_at > window_start)
);

alter table public.wearable_daily_totals enable row level security;
revoke all on public.wearable_daily_totals from public, anon, authenticated;
grant select, insert, delete on public.wearable_daily_totals to authenticated;
grant update (source, value, captured_at) on public.wearable_daily_totals to authenticated;
create policy nova_wearable_daily_access on public.wearable_daily_totals
  for all to authenticated using (true) with check (true);
create policy nova_account_boundary on public.wearable_daily_totals
  as restrictive for all to public using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create function public.save_wearable_daily_totals(expected_account uuid, totals jsonb)
returns integer language plpgsql security invoker set search_path = pg_catalog
as $$
declare
  account_id uuid := auth.uid();
  changed integer;
begin
  if account_id is null or account_id is distinct from expected_account then
    raise insufficient_privilege using message = 'Use the account that opened the import';
  end if;
  if jsonb_typeof(totals) is distinct from 'array' then
    raise invalid_parameter_value using message = 'Invalid wearable import';
  end if;
  if jsonb_array_length(totals) not between 1 and 7 or exists (
    select from jsonb_to_recordset(totals) as row_data(captured_at timestamptz)
    where captured_at is null or captured_at > clock_timestamp() + interval '5 minutes'
  ) then
    raise invalid_parameter_value using message = 'Invalid wearable import';
  end if;

  insert into public.wearable_daily_totals as existing
    (user_id, metric, local_date, window_start, window_end, captured_at, source, value)
  select account_id, metric, local_date, window_start, window_end, captured_at, source, value
  from jsonb_to_recordset(totals) as entry(
    metric text, local_date date, window_start timestamptz, window_end timestamptz,
    captured_at timestamptz, source text, value integer
  )
  on conflict (user_id, metric, local_date, window_start, window_end) do update
    set value = excluded.value, source = excluded.source, captured_at = excluded.captured_at
    where excluded.captured_at > existing.captured_at;

  get diagnostics changed = row_count;
  return changed;
end
$$;
revoke all on function public.save_wearable_daily_totals(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.save_wearable_daily_totals(uuid, jsonb) to authenticated;

commit;
