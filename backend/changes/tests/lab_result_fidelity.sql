-- Use only in the disposable test cluster. Run once with -v h6_before_migration=1
-- before 009, then run again without the variable after 009.
\if :{?h6_before_migration}
set role h1_auth_admin;
insert into auth.users (id, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000601', '{}'),
  ('00000000-0000-0000-0000-000000000602', '{}');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000601', false);
insert into public.lab_results (user_id, test_name, value, unit, ref_low, ref_high, flag, reported_on)
values (auth.uid(), 'Legacy synthetic test', 12.10, 'g/L', 10, 20, 'normal', '2025-01-02');
\else
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000601', true);

do $$
begin
  if not exists (select from public.lab_results where user_id = auth.uid()
      and test_name = 'Legacy synthetic test' and value = 12.10 and value_text is null
      and unit = 'g/L' and ref_low = 10 and ref_high = 20 and flag = 'normal'
      and reported_on = '2025-01-02' and reference_text is null and extracted_value_text is null) then
    raise exception '009 changed an existing lab record';
  end if;
end $$;

insert into public.lab_results
  (user_id, test_name, value, value_text, unit, reference_text, reported_flag, flag, extracted_value_text, source)
values
  (auth.uid(), 'Synthetic threshold', null, '<=0.40', 'mg/L', '>0.10 (method A)', '↑', 'high', '<=0.50', 'scan_reviewed'),
  (auth.uid(), 'Synthetic exact', 1.2300, '1.2300', 'mmol/L', '0.100–2.000', null, 'unknown', null, 'scan_reviewed'),
  (auth.uid(), 'Synthetic qualitative', null, 'Indeterminate', null, null, 'Check', 'unknown', null, 'scan_reviewed');

do $$
declare bad record;
begin
  if not exists (select from public.lab_results where test_name = 'Synthetic threshold'
      and value is null and value_text = '<=0.40' and reported_on is null
      and extracted_value_text = '<=0.50' and reference_text = '>0.10 (method A)' and reported_flag = '↑')
     or not exists (select from public.lab_results where test_name = 'Synthetic exact' and value_text = '1.2300' and value = 1.23)
     or not exists (select from public.lab_results where test_name = 'Synthetic qualitative' and value is null and flag = 'unknown') then
    raise exception 'Reviewed observations did not round-trip';
  end if;
  for bad in select * from (values
    ('>0.4', 0.4::numeric, 'unknown'), ('7.4', 7.5, 'unknown'), ('7.4', null, 'unknown'),
    ('Unknown', null, 'normal'), ('<=', null, 'unknown'), (E'\t', null, 'unknown'), (null, null, 'unknown')
  ) as cases(printed, measurement, result_flag) loop
    begin
      insert into public.lab_results (user_id, test_name, value_text, value, flag, source)
      values (auth.uid(), 'Invalid synthetic result', bad.printed, bad.measurement, bad.result_flag, 'scan_reviewed');
      raise exception 'Accepted invalid reviewed observation: %', bad;
    exception when check_violation then null;
    end;
  end loop;
end $$;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000602', true);
do $$
begin
  if exists (select from public.lab_results) then
    raise exception 'Another account could read lab results';
  end if;
  update public.lab_results set value_text = 'Altered';
  if found then raise exception 'Another account could edit lab results'; end if;
  delete from public.lab_results;
  if found then raise exception 'Another account could delete lab results'; end if;
  begin
    insert into public.lab_results (user_id, test_name, value_text, source)
    values ('00000000-0000-0000-0000-000000000601', 'Wrong account', 'Negative', 'scan_reviewed');
    raise exception 'Another account could insert lab results';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
\endif
