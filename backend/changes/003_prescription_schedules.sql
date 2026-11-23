-- Store the reviewed prescription separately from notification preferences.
-- Existing medication rows keep their clock times and notification behavior.
alter table public.medications
  add column if not exists prescription_plan jsonb,
  add column if not exists reminders_enabled boolean not null default true;
