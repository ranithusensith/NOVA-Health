-- Run after 016 on an approved environment with pg_cron enabled, as the migration owner.
-- Scheduling the same name again updates the existing job.
select cron.schedule(
  'nova-automatic-daily-reports',
  '*/5 * * * *',
  'select public.generate_due_daily_reports()'
);
