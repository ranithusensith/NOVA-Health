-- Account-owned tracking preferences. NULL means the patient has not set a target.
begin;

alter table public.profiles
  add column if not exists water_goal_ml integer,
  add column if not exists sleep_goal_hours numeric,
  add constraint nova_water_goal_range check (water_goal_ml between 1 and 20000),
  add constraint nova_sleep_goal_range check (sleep_goal_hours between 0.1 and 24);

commit;
