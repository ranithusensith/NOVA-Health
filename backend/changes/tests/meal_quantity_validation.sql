-- Disposable database only. The pre-migration case is committed to test the upgrade.
\if :{?p14_before_migration}
insert into auth.users (id, raw_user_meta_data) values
  ('a1500000-0000-0000-0000-000000000001', '{"full_name":"Synthetic meal owner"}'),
  ('a1500000-0000-0000-0000-000000000002', '{"full_name":"Synthetic other owner"}');
insert into public.meal_logs (user_id, description, calories, nutrients) values
  ('a1500000-0000-0000-0000-000000000001', 'Legacy synthetic meal', -10, '{"protein_g":"unknown"}');
\else
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1500000-0000-0000-0000-000000000001', true);
insert into public.meal_logs (user_id, description, calories, nutrients)
values (auth.uid(), 'Corrected synthetic meal', 420, '{"protein_g":12.4,"carbs_g":0,"fat_g":null}'),
       (auth.uid(), 'Unknown quantities', null, null);

do $$
declare
  bad jsonb;
  bad_calories integer;
begin
  if not exists (select from public.meal_logs where description = 'Legacy synthetic meal' and calories = -10)
    then raise exception 'Legacy row was changed'; end if;
  if not exists (select from public.meal_logs where description = 'Corrected synthetic meal' and calories = 420
    and nutrients = '{"protein_g":12.4,"carbs_g":0,"fat_g":null}')
    then raise exception 'Corrected values did not round-trip'; end if;
  if not exists (select from public.meal_logs where description = 'Unknown quantities' and calories is null
    and nutrients is null) then raise exception 'Unknown values did not round-trip'; end if;
  foreach bad_calories in array array[-1,5001] loop
    begin
      insert into public.meal_logs (user_id, description, calories) values (auth.uid(), 'Invalid', bad_calories);
      raise exception 'Invalid calories accepted';
    exception when check_violation then null;
    end;
  end loop;
  foreach bad in array array['[]', 'null', '{"protein_g":"12"}', '{"fat_g":false}', '{"carbs_g":[1]}',
    '{"fat_g":"NaN"}', '{"protein_g":-1}', '{"carbs_g":801}', '{"protein_g":1.11}', '{"fiber_mg":1}']::jsonb[] loop
    begin
      insert into public.meal_logs (user_id, description, nutrients) values (auth.uid(), 'Invalid', bad);
      raise exception 'Invalid nutrients accepted';
    exception when check_violation then null;
    end;
  end loop;
  begin
    insert into public.meal_logs (user_id, description, calories)
    values ('a1500000-0000-0000-0000-000000000002', 'Wrong owner', 420);
    raise exception 'Cross-account meal insert accepted';
  exception when insufficient_privilege then null;
  end;
end
$$;

select set_config('request.jwt.claim.sub', 'a1500000-0000-0000-0000-000000000002', true);
do $$
begin
  if exists (select from public.meal_logs) then raise exception 'Cross-account meal read'; end if;
end
$$;
rollback;
\endif
