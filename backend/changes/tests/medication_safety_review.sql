-- Disposable cluster only. The signing key and accounts are synthetic.
begin;
insert into auth.users (id, raw_user_meta_data) values
  ('a1100000-0000-0000-0000-000000000001', '{"full_name":"Synthetic Account One"}'),
  ('a1100000-0000-0000-0000-000000000002', '{"full_name":"Synthetic Account Two"}');
insert into public.nova_medication_signing_key (signing_key) values (decode(repeat('a1', 32), 'hex'));

create function pg_temp.assert_test(ok boolean, reason text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception '%', reason; end if;
end
$$;

create function pg_temp.sign_review(payload text) returns text language sql as $$
  select encode(extensions.hmac(convert_to('medication-write:' || payload, 'UTF8'), signing_key, 'sha256'), 'hex')
  from public.nova_medication_signing_key
$$;
revoke all on function pg_temp.sign_review(text) from public;

select jsonb_build_object(
  'account', 'a1100000-0000-0000-0000-000000000001',
  'expires', extract(epoch from clock_timestamp())::bigint + 60,
  'context_version', version,
  'rows', '[
    {"id":"a1100000-0000-0000-0000-000000000011","user_id":"a1100000-0000-0000-0000-000000000001",
     "name":"Synthetic manual medicine","dosage":"Initial dose","times":["07:00"],"start_date":"2026-11-23",
     "source":"manual","status":"confirmed","prescription_plan":{"kind":"daily","instructions":"Original directions"},
     "reminders_enabled":false},
    {"id":"a1100000-0000-0000-0000-000000000012","user_id":"a1100000-0000-0000-0000-000000000001",
     "name":"Synthetic scanned medicine","times":[],"start_date":"2026-11-23",
     "source":"scan","status":"confirmed","prescription_plan":{"kind":"as_needed","instructions":"Original PRN directions"},
     "reminders_enabled":false}
  ]'::jsonb
)::text as create_payload from public.nova_medication_context_versions
where user_id = 'a1100000-0000-0000-0000-000000000001' \gset
select pg_temp.sign_review(:'create_payload') as create_signature,
       jsonb_set(:'create_payload'::jsonb, '{expires}', '0')::text as expired_payload \gset
select pg_temp.sign_review(:'expired_payload') as expired_signature \gset

set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1100000-0000-0000-0000-000000000002', true);
select set_config('nova_test.create_payload', :'create_payload', true);
select set_config('nova_test.create_signature', :'create_signature', true);
select set_config('nova_test.expired_payload', :'expired_payload', true);
select set_config('nova_test.expired_signature', :'expired_signature', true);
do $$
begin
  begin
    perform public.save_reviewed_medications(current_setting('nova_test.create_payload'), current_setting('nova_test.create_signature'));
    raise exception 'Cross-account signed payload was accepted';
  exception when insufficient_privilege then null;
  end;
end
$$;

select set_config('request.jwt.claim.sub', 'a1100000-0000-0000-0000-000000000001', true);
do $$
begin
  begin
    insert into public.medications (user_id, name, source) values (auth.uid(), 'Older client', 'scan');
    raise exception 'Direct activation was accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform signing_key from public.nova_medication_signing_key;
    raise exception 'Signing key was visible to the account';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.save_reviewed_medications('{}', repeat('a1', 32));
    raise exception 'Unsigned activation was accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.save_reviewed_medications(
      replace(current_setting('nova_test.create_payload'), 'Initial dose', 'Unreviewed dose'),
      current_setting('nova_test.create_signature')
    );
    raise exception 'Tampered activation was accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.save_reviewed_medications(current_setting('nova_test.expired_payload'), current_setting('nova_test.expired_signature'));
    raise exception 'Expired activation was accepted';
  exception when insufficient_privilege then null;
  end;
end
$$;

select public.medication_safety_version() as initial_context \gset
update public.profiles set conditions = array['Synthetic condition'] where id = auth.uid();
select pg_temp.assert_test(
  public.medication_safety_version() is distinct from :'initial_context'::uuid,
  'Changed conditions left the original review version current'
);
select public.medication_safety_version() as profile_context \gset
insert into public.allergies (user_id, name) values (auth.uid(), 'Synthetic changed allergy');
select pg_temp.assert_test(
  public.medication_safety_version() is distinct from :'profile_context'::uuid,
  'Changed allergies left the original review version current'
);
select pg_temp.assert_test(
  not public.save_reviewed_medications(:'create_payload', :'create_signature'),
  'A review accepted after its safety inputs changed'
);
reset role;
select jsonb_set(:'create_payload'::jsonb, '{context_version}', to_jsonb(version))::text as current_payload
from public.nova_medication_context_versions where user_id = 'a1100000-0000-0000-0000-000000000001' \gset
select pg_temp.sign_review(:'current_payload') as current_signature \gset
set local role authenticated;
select public.medication_safety_version() as checked_context \gset
select pg_temp.assert_test(public.save_reviewed_medications(:'current_payload', :'current_signature'), 'Reviewed batch did not save');
select pg_temp.assert_test(
  public.medication_safety_version() is distinct from :'checked_context'::uuid,
  'Changed medications left the original review version current'
);
select pg_temp.assert_test(count(*) = 2, 'Account cannot read both reviewed rows') from public.medications;

do $$
begin
  begin
    update public.medications set dosage = 'Unreviewed dose' where source = 'manual';
    raise exception 'Direct detail update was accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.medications set end_date = '2026-11-24' where source = 'manual';
    raise exception 'Direct schedule update was accepted';
  exception when insufficient_privilege then null;
  end;
end
$$;

reset role;
select jsonb_build_object(
  'account', user_id,
  'expires', extract(epoch from clock_timestamp())::bigint + 60,
  'expected_revision', review_revision,
  'context_version', (select version from public.nova_medication_context_versions where user_id = m.user_id),
  'rows', jsonb_build_array(to_jsonb(m) || '{"dosage":"Reviewed edit","times":["19:00"]}'::jsonb)
)::text as edit_payload
from public.medications m where id = 'a1100000-0000-0000-0000-000000000011' \gset
select pg_temp.sign_review(:'edit_payload') as edit_signature \gset

set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1100000-0000-0000-0000-000000000002', true);
update public.medications set status = 'ended', end_date = '2026-11-25';
select pg_temp.assert_test(count(*) = 0, 'RLS exposed another account''s rows') from public.medications;
select pg_temp.assert_test(
  not has_function_privilege('anon', 'public.save_reviewed_medications(text,text)', 'EXECUTE'),
  'Anonymous role can call the reviewed writer'
);

select set_config('request.jwt.claim.sub', 'a1100000-0000-0000-0000-000000000001', true);
select pg_temp.assert_test(public.save_reviewed_medications(:'edit_payload', :'edit_signature'), 'Reviewed edit did not save');
select pg_temp.assert_test(not public.save_reviewed_medications(:'edit_payload', :'edit_signature'), 'A stale edit was replayed');
select pg_temp.assert_test(
  count(*) = 1, 'Reviewed edit lost the original directions, timing or reminder preference'
)
from public.medications
where id = 'a1100000-0000-0000-0000-000000000011' and dosage = 'Reviewed edit' and times = array['19:00']
  and prescription_plan = '{"kind":"daily","instructions":"Original directions"}' and not reminders_enabled;

update public.medications set status = 'ended', end_date = '2026-11-25'
where id = 'a1100000-0000-0000-0000-000000000011';
select pg_temp.assert_test(count(*) = 1, 'Owner could not stop medication')
from public.medications where status = 'ended' and end_date = '2026-11-25';

do $$
begin
  begin
    update public.medications set status = 'confirmed' where status = 'ended';
    raise exception 'Direct reactivation was accepted';
  exception when insufficient_privilege then null;
  end;
end
$$;

insert into public.medication_logs (user_id, medication_id, taken_at)
values (auth.uid(), 'a1100000-0000-0000-0000-000000000011', '2026-11-24T07:00:00Z');
select pg_temp.assert_test(count(*) = 1, 'Dose history write failed after migration') from public.medication_logs;

rollback;
