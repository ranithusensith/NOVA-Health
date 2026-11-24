-- Each database check raises an exception on failure.
set role h1_auth_admin;
insert into auth.users values
  ('00000000-0000-0000-0000-000000000003', '{"full_name":" New User "}'),
  ('00000000-0000-0000-0000-000000000004', null);
reset role;

set role h1_migration_owner;
do $$
declare
  app_table text;
begin
  if (select count(*) from public.profiles) <> (select count(*) from auth.users)
     or not exists (select from public.profiles
       where id = '00000000-0000-0000-0000-000000000003'
         and btrim(full_name) = 'New User' and not onboarding_done
         and conditions = '{}' and goals = '{}' and birth_date is null and medical_notes is null)
     or not exists (select from public.profiles
       where id = '00000000-0000-0000-0000-000000000004' and full_name is null)
     or exists (select from public.ai_processing_consents) then
    raise exception 'Invalid signup profile or default consent';
  end if;

  foreach app_table in array array[
    'profiles', 'allergies', 'medications', 'medication_logs', 'water_logs', 'sleep_logs',
    'mood_logs', 'meal_logs', 'symptom_logs', 'wearable_samples', 'period_logs',
    'emergency_contacts', 'audit_log', 'lab_results', 'ai_processing_consents'
  ] loop
    if not exists (select from pg_class where oid = format('public.%I', app_table)::regclass
                   and relrowsecurity and relowner = 'h1_migration_owner'::regrole)
       or not exists (select from pg_policy where polrelid = format('public.%I', app_table)::regclass
                      and polname = 'nova_account_boundary' and not polpermissive)
       or has_table_privilege('anon', format('public.%I', app_table), 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
       or has_table_privilege('authenticated', format('public.%I', app_table), 'TRUNCATE,REFERENCES,TRIGGER') then
      raise exception 'Unsafe privileges, ownership or RLS on %', app_table;
    end if;
  end loop;
  if has_table_privilege('authenticated', 'auth.users', 'SELECT,INSERT,UPDATE,DELETE')
     or has_table_privilege('h1_auth_admin', 'public.profiles', 'INSERT')
     or has_function_privilege('authenticated', 'public.nova_create_health_profile()', 'EXECUTE')
     or has_function_privilege('anon', 'public.nova_create_health_profile()', 'EXECUTE')
     or has_function_privilege('anon', 'public.delete_legacy_ai_chats()', 'EXECUTE') then
    raise exception 'Unexpected Auth or function privileges';
  end if;

  if to_regclass('public.chat_messages') is not null then
    if not exists (select from public.profiles
         where id = '00000000-0000-0000-0000-000000000001' and full_name = 'Edited Name')
       or not exists (select from public.profiles
         where id = '00000000-0000-0000-0000-000000000002' and full_name = 'Missing Profile')
       or not exists (select from public.medications where name = 'Legacy medication'
         and times = array['08:00'] and reminders_enabled and prescription_plan is null)
       or not exists (select from public.medication_logs where status = 'taken')
       or (select count(*) from public.chat_messages) <> 2 then
      raise exception 'Legacy migration lost or changed data';
    end if;
  end if;
end
$$;
reset role;

set role authenticated;
-- The role alone grants no rows without an authenticated subject.
do $$
begin
  if exists (select from public.profiles) then raise exception 'Missing subject exposed profiles'; end if;
  begin
    perform public.delete_legacy_ai_chats();
    raise exception 'Cleanup RPC accepted missing subject';
  exception when insufficient_privilege then null;
  end;
end
$$;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', false);
update public.profiles set onboarding_done = true, conditions = array['Synthetic condition']
where id = '00000000-0000-0000-0000-000000000003';
insert into public.allergies (user_id, name) values (auth.uid(), 'Synthetic allergen');
insert into public.medications (id, user_id, name, times, start_date) values
  ('00000000-0000-0000-0000-000000000103', auth.uid(), 'Manual medication', array['08:00'], current_date);
insert into public.medications (user_id, name, times, start_date, end_date, prescription_plan, source)
values (auth.uid(), 'Reviewed medication', '{}', current_date, current_date + 6,
  '{"interval_minutes":480,"first_dose_at":"2026-11-24T08:00:00Z"}', 'scan');
update public.medications set reminders_enabled = false where name = 'Reviewed medication';
insert into public.medication_logs (user_id, medication_id)
values (auth.uid(), '00000000-0000-0000-0000-000000000103');
insert into public.water_logs (user_id, amount_ml) values (auth.uid(), 250);
insert into public.sleep_logs (user_id, hours) values (auth.uid(), 7.5);
insert into public.mood_logs (user_id, mood) values (auth.uid(), 'ok');
insert into public.meal_logs (user_id, description, calories, nutrients, source)
values (auth.uid(), 'Synthetic meal', 300, '{"protein_g":12}', 'scan');
insert into public.wearable_samples (user_id, metric, value, device, recorded_at)
values (auth.uid(), 'heart_rate', 70, 'apple_health', '2026-11-24 08:00:00+00');
insert into public.wearable_samples (user_id, metric, value, device, recorded_at)
values (auth.uid(), 'heart_rate', 90, 'apple_health', '2026-11-24 08:00:00+00')
on conflict (user_id, metric, device, recorded_at) do nothing;
insert into public.period_logs (user_id, start_date, flow) values (auth.uid(), current_date, 'medium');
update public.period_logs set end_date = current_date where user_id = auth.uid();
insert into public.emergency_contacts (user_id, name, phone)
values (auth.uid(), 'Synthetic contact', '+10000000000') returning id;
insert into public.audit_log (user_id, action, detail) values (auth.uid(), 'sos_triggered', '{"contacts":1}');
insert into public.lab_results (user_id, test_name, value, flag) values (auth.uid(), 'Synthetic lab', 5, 'normal');
insert into public.ai_processing_consents (user_id, disclosure_version) values (auth.uid(), 'synthetic-v1')
on conflict (user_id) do update set disclosure_version = excluded.disclosure_version;

do $$
begin
  if (select count(*) from public.profiles) <> 1
     or not exists (select from public.profiles where onboarding_done)
     or not exists (select from public.medication_logs where status = 'taken')
     or (select count(*) from public.wearable_samples) <> 1
     or not exists (select from public.wearable_samples where value = 70)
     or not exists (select from public.medications where prescription_plan is not null and not reminders_enabled)
     or public.delete_legacy_ai_chats() <> 0 then
    raise exception 'Owner workflow failed';
  end if;
end
$$;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', false);
do $$
begin
  if exists (select from public.medications) or exists (select from public.medication_logs)
     or exists (select from public.lab_results) or exists (select from public.ai_processing_consents)
     or (select count(*) from public.profiles) <> 1 then
    raise exception 'Cross-account read was allowed';
  end if;
  update public.medications set reminders_enabled = true;
  if found then raise exception 'Cross-account update was allowed'; end if;
  delete from public.lab_results;
  if found then raise exception 'Cross-account delete was allowed'; end if;
  begin
    insert into public.water_logs (user_id, amount_ml)
    values ('00000000-0000-0000-0000-000000000003', 250);
    raise exception 'Cross-account insert was allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.medication_logs (user_id, medication_id)
    values (auth.uid(), '00000000-0000-0000-0000-000000000103');
    raise exception 'Cross-account medication reference was allowed';
  exception when foreign_key_violation then null;
  end;
  begin
    truncate public.medications;
    raise exception 'Authenticated truncate was allowed';
  exception when insufficient_privilege then null;
  end;
  if to_regclass('public.chat_messages') is not null then
    begin
      update public.profiles set full_name = 'Blocked by legacy policy';
      raise exception 'Legacy policy was weakened';
    exception when insufficient_privilege then null;
    end;
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
    if public.delete_legacy_ai_chats() <> 1 or public.delete_legacy_ai_chats() <> 0 then
      raise exception 'Legacy cleanup returned an invalid count';
    end if;
  end if;
end
$$;
reset role;

set role h1_migration_owner;
do $$
begin
  if to_regclass('public.chat_messages') is not null then
    if (select count(*) from public.chat_messages) <> 1
       or not exists (select from public.chat_messages where content = 'Second synthetic chat') then
      raise exception 'Legacy cleanup crossed accounts';
    end if;
  end if;
end
$$;
reset role;
