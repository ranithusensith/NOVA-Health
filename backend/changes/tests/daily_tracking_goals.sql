-- Use only on the disposable fixture databases.
begin;
insert into auth.users (id, raw_user_meta_data) values
  ('a1200000-0000-0000-0000-000000000001', '{"full_name":"Synthetic Tracking One"}'),
  ('a1200000-0000-0000-0000-000000000002', '{"full_name":"Synthetic Tracking Two"}');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1200000-0000-0000-0000-000000000001', true);
do $$
begin
  if not exists (select from public.profiles where id = auth.uid()
                 and water_goal_ml is null and sleep_goal_hours is null) then
    raise exception 'Goals must start unknown';
  end if;
  update public.profiles set water_goal_ml = 750, sleep_goal_hours = 6.5 where id = auth.uid();
  if not found then raise exception 'Owner cannot update goals'; end if;
  begin
    update public.profiles set water_goal_ml = -1 where id = auth.uid();
    raise exception 'Invalid water target accepted';
  exception when check_violation then null;
  end;
  begin
    update public.profiles set sleep_goal_hours = 'NaN' where id = auth.uid();
    raise exception 'Invalid sleep goal accepted';
  exception when check_violation then null;
  end;
end
$$;

select set_config('request.jwt.claim.sub', 'a1200000-0000-0000-0000-000000000002', true);
do $$
begin
  if exists (select from public.profiles where water_goal_ml = 750) then
    raise exception 'Read another account goal';
  end if;
  update public.profiles set water_goal_ml = 3500 where id = 'a1200000-0000-0000-0000-000000000001';
  if found then raise exception 'Updated another account goal'; end if;
  update public.profiles set water_goal_ml = 2000, sleep_goal_hours = 8 where id = auth.uid();
end
$$;

select set_config('request.jwt.claim.sub', 'a1200000-0000-0000-0000-000000000001', true);
do $$
begin
  if not exists (select from public.profiles where water_goal_ml = 750 and sleep_goal_hours = 6.5) then
    raise exception 'First account did not retain its own goals';
  end if;
  update public.profiles set water_goal_ml = null, sleep_goal_hours = null where id = auth.uid();
  if not exists (select from public.profiles where id = auth.uid()
                 and water_goal_ml is null and sleep_goal_hours is null) then
    raise exception 'Owner cannot clear goals';
  end if;
end
$$;
rollback;
