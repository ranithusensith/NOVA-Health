-- Run only in the disposable PostgreSQL verification cluster.
begin;

set local role h1_auth_admin;
insert into auth.users values
  ('00000000-0000-0000-0000-000000000005', '{"full_name":"Synthetic A"}'),
  ('00000000-0000-0000-0000-000000000006', '{"full_name":"Synthetic B"}');
reset role;

set local role h1_migration_owner;
insert into public.allergies (id, user_id, name, source, status) values
  ('00000000-0000-0000-0000-000000000105', '00000000-0000-0000-0000-000000000005', 'Keep', 'scan', 'confirmed'),
  ('00000000-0000-0000-0000-000000000205', '00000000-0000-0000-0000-000000000005', 'Remove', 'user', 'confirmed'),
  ('00000000-0000-0000-0000-000000000305', '00000000-0000-0000-0000-000000000005', 'Pending', 'scan', 'pending'),
  ('00000000-0000-0000-0000-000000000106', '00000000-0000-0000-0000-000000000006', 'Other account', 'user', 'confirmed');

-- Fail during INSERT after verifying that the old allergy was already deleted.
create function public.test_fail_allergy_insert() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.name = 'Synthetic insert failure' then
    if exists (select from public.allergies where user_id = new.user_id and name = 'Remove') then
      raise exception 'Failure was injected before deletion';
    end if;
    raise check_violation using message = 'Synthetic insert failure';
  end if;
  return new;
end
$$;
create trigger test_fail_allergy_insert before insert on public.allergies
  for each row execute function public.test_fail_allergy_insert();

create policy test_restrict_allergy_delete on public.allergies as restrictive
  for delete to authenticated using (name <> 'Keep');
create policy test_restrict_profile_update on public.profiles as restrictive
  for update to authenticated with check (full_name <> 'Synthetic blocked profile');

do $$
declare
  rpc constant regprocedure :=
    'public.save_health_profile(uuid,text,date,text,text,numeric,numeric,text[],text,text[])'::regprocedure;
begin
  if has_function_privilege('anon', rpc, 'EXECUTE')
     or not has_function_privilege('authenticated', rpc, 'EXECUTE')
     or (select prosecdef from pg_proc where oid = rpc) then
    raise exception 'Unexpected profile RPC privileges';
  end if;
end
$$;

set local role anon;
do $$
begin
  begin
    perform public.save_health_profile('00000000-0000-0000-0000-000000000005',
      'Anonymous change', '1995-05-05', 'other', null, 170, 65, '{}', null, '{}');
    raise exception 'Anonymous role could save';
  exception when insufficient_privilege then null;
  end;
end
$$;

set local role authenticated;
do $$
declare
  alice constant uuid := '00000000-0000-0000-0000-000000000005';
  bob constant uuid := '00000000-0000-0000-0000-000000000006';
  added_id uuid;
  invalid_height numeric;
begin
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.save_health_profile(alice, 'Missing subject', '1995-05-05',
      'other', null, 170, 65, '{}', null, '{}');
    raise exception 'Authenticated role without subject could save';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', alice::text, true);
  begin
    perform public.save_health_profile(bob, 'Wrong owner', '1995-05-05',
      'other', null, 170, 65, '{}', null, '{}');
    raise exception 'Cross-account save was permitted';
  exception when insufficient_privilege then null;
  end;
  foreach invalid_height in array array[49, 251, 'NaN'::numeric, 'Infinity'::numeric] loop
    begin
      perform public.save_health_profile(alice, 'Invalid measurement', '1995-05-05',
        'other', null, invalid_height, 65, '{}', null, '{}');
      raise exception 'Invalid measurement was accepted';
    exception when invalid_parameter_value then null;
    end;
  end loop;
  begin
    perform public.save_health_profile(alice, 'Invalid allergy array', '1995-05-05',
      'other', null, 170, 65, '{}', null, array[null::text]);
    raise exception 'Invalid allergy array was accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.save_health_profile(alice, 'Rolled back profile', '1995-05-05',
      'other', 'unknown', 170, 65, '{Synthetic condition}', 'Synthetic notes',
      '{Keep,"Synthetic insert failure"}');
    raise exception 'Expected an insert error';
  exception when check_violation then
    if sqlerrm <> 'Synthetic insert failure' then raise; end if;
  end;
  begin
    perform public.save_health_profile(alice, 'Restricted delete', '1995-05-05',
      'other', null, 170, 65, '{}', null, '{New}');
    raise exception 'Save succeeded despite a restricted deletion';
  exception when insufficient_privilege then
    if sqlerrm <> 'Could not save the complete allergy list.' then raise; end if;
  end;
  begin
    perform public.save_health_profile(alice, 'Synthetic blocked profile', '1995-05-05',
      'other', null, 170, 65, '{}', null, '{Keep,New}');
    raise exception 'Save succeeded despite a restricted profile update';
  exception when insufficient_privilege then
    if sqlerrm not like '%row-level security%profiles%' then raise; end if;
  end;
  if not exists (select from public.profiles where id = alice and full_name = 'Synthetic A'
                and birth_date is null and not onboarding_done)
     or (select array_agg(name order by name) from public.allergies where user_id = alice)
        is distinct from array['Keep', 'Pending', 'Remove'] then
    raise exception 'Failure changed the profile, onboarding, or allergy list';
  end if;

  perform public.save_health_profile(alice, '  Saved profile  ', '1995-05-05',
    'other', 'unknown', 170, 65, '{Synthetic condition}', 'Synthetic notes', '{keep," new ",New,"  "}');
  select id into strict added_id from public.allergies where user_id = alice and name = 'New';
  -- A retry after an ambiguous response must preserve the inserted allergy ID.
  perform public.save_health_profile(alice, 'Saved profile', '1995-05-05',
    'other', 'unknown', 170, 65, '{Synthetic condition}', 'Synthetic notes', '{Keep,New}');
  if not exists (select from public.profiles where id = alice and full_name = 'Saved profile'
                and birth_date = '1995-05-05' and sex = 'other' and blood_type = 'unknown'
                and height_cm = 170 and weight_kg = 65 and conditions = '{Synthetic condition}'
                and medical_notes = 'Synthetic notes' and onboarding_done)
     or (select count(*) from public.allergies where user_id = alice) <> 3
     or not exists (select from public.allergies where id = '00000000-0000-0000-0000-000000000105'
                    and name = 'Keep' and source = 'scan' and status = 'confirmed')
     or not exists (select from public.allergies where id = added_id and source = 'user' and status = 'confirmed')
     or not exists (select from public.allergies where name = 'Pending' and status = 'pending') then
    raise exception 'Save or retry changed the expected profile or allergy details';
  end if;

  perform set_config('request.jwt.claim.sub', bob::text, true);
  if not exists (select from public.profiles where id = bob and full_name = 'Synthetic B' and not onboarding_done)
     or (select array_agg(name) from public.allergies where user_id = bob)
        is distinct from array['Other account'] then
    raise exception 'Save changed the other account';
  end if;
  perform public.save_health_profile(bob, 'Saved without allergies', '1995-05-05',
    'other', null, 170, 65, '{}', null, '{}');
  if exists (select from public.allergies where user_id = bob)
     or not exists (select from public.profiles where id = bob and onboarding_done) then
    raise exception 'Could not intentionally clear confirmed allergies';
  end if;
end
$$;
rollback;
