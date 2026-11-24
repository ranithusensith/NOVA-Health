-- Preserve timestamp-only history. New scheduled logs identify one occurrence.
begin;

alter table public.medication_logs
  alter column taken_at set default now(),
  add column scheduled_at timestamptz,
  add column scheduled_local_at timestamp without time zone,
  add column occurrence_key text generated always as (
    case
      when scheduled_local_at is not null
        then 'daily:' || ((extract(epoch from scheduled_local_at) * 1000000)::bigint)::text
      when scheduled_at is not null
        then 'interval:' || ((extract(epoch from scheduled_at at time zone 'UTC') * 1000000)::bigint)::text
    end
  ) stored,
  add constraint nova_scheduled_dose_taken check (
    scheduled_at is null or status is not distinct from 'taken'
  ),
  add constraint nova_dose_local_time check (
    scheduled_local_at is null or (
      scheduled_at is not null
      and scheduled_local_at = date_trunc('minute', scheduled_local_at)
      and abs(extract(epoch from (scheduled_local_at - (scheduled_at at time zone 'UTC')))) < 86400
    )
  );

-- NULL keys are deliberately distinct for legacy rows.
create unique index nova_medication_logs_occurrence
  on public.medication_logs (user_id, medication_id, occurrence_key);
create index nova_medication_logs_owner_scheduled_time
  on public.medication_logs (user_id, scheduled_at);
create index nova_medication_logs_owner_local_time
  on public.medication_logs (user_id, scheduled_local_at);

commit;
