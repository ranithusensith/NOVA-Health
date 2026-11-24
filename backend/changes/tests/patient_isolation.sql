-- Run after verify.sql, as the disposable cluster administrator.
begin;

insert into public.symptom_logs (user_id, name)
values ('00000000-0000-0000-0000-000000000003', 'Synthetic symptom');
insert into public.medications (id, user_id, name, times)
values ('00000000-0000-0000-0000-000000000104',
        '00000000-0000-0000-0000-000000000004', 'Synthetic parent', '{}');

create temp table patient_cases (
  table_name text, owner_column text, key_column text, allowed text[], samples jsonb, insert_columns text
);
insert into patient_cases (table_name, owner_column, key_column, allowed) values
  ('profiles', 'id', 'id', '{select,update}'),
  ('allergies', 'user_id', 'id', '{select,insert,delete}'),
  ('medications', 'user_id', 'id', '{select,insert,update}'),
  ('medication_logs', 'user_id', 'id', '{select,insert,delete}'),
  ('water_logs', 'user_id', 'id', '{select,insert}'),
  ('sleep_logs', 'user_id', 'id', '{select,insert}'),
  ('mood_logs', 'user_id', 'id', '{select,insert}'),
  ('meal_logs', 'user_id', 'id', '{select,insert}'),
  ('symptom_logs', 'user_id', 'id', '{select}'),
  ('wearable_samples', 'user_id', 'id', '{select,insert,delete}'),
  ('period_logs', 'user_id', 'id', '{select,insert,update,delete}'),
  ('emergency_contacts', 'user_id', 'id', '{select,insert,delete}'),
  ('audit_log', 'user_id', 'id', '{insert}'),
  ('lab_results', 'user_id', 'id', '{select,insert,update,delete}'),
  ('ai_processing_consents', 'user_id', 'user_id', '{select,insert,update,delete}');

do $$
declare
  subject_a constant uuid := '00000000-0000-0000-0000-000000000003';
  subject_b constant uuid := '00000000-0000-0000-0000-000000000004';
  spec record;
  target regclass;
  row_a jsonb;
  row_b jsonb;
  operation text;
  writable_columns text;
begin
  if to_regclass('public.chat_messages') is not null then
    insert into public.chat_messages (user_id, content)
    values (subject_a, 'H2 chat A'), (subject_b, 'H2 chat B');
    insert into patient_cases (table_name, owner_column, allowed) values ('chat_messages', 'user_id', '{}');
  end if;
  for spec in select * from patient_cases loop
    target := format('public.%I', spec.table_name)::regclass;
    select string_agg(quote_ident(attname), ', ' order by attnum) into writable_columns
      from pg_attribute
      where attrelid = target and attnum > 0 and not attisdropped and attgenerated = '';
    if not exists (select from pg_class where oid = target and relrowsecurity)
       or not exists (
         select from pg_policy where polrelid = target and polname = 'nova_account_boundary'
           and not polpermissive and polcmd = '*' and polroles = array[0::oid]
           and polqual is not null and polwithcheck is not null
       ) then
      raise exception 'Missing restrictive owner policy on %', target;
    end if;
    foreach operation in array array['select', 'insert', 'update', 'delete', 'truncate', 'references', 'trigger']
    loop
      if has_table_privilege('anon', target, operation)
         or (operation = any(array['select','insert','update','references'])
             and has_any_column_privilege('anon', target, operation))
         or (operation <> all(spec.allowed) and (
               has_table_privilege('authenticated', target, operation)
               or (operation = any(array['select','insert','update','references'])
                   and has_any_column_privilege('authenticated', target, operation))
            )) then
        raise exception 'Unexpected privilege % on %', operation, target;
      end if;
    end loop;
    execute format('select to_jsonb(t) from %s t where %I = $1 %s limit 1',
                   target, spec.owner_column,
                   case when spec.table_name = 'medications' then 'and prescription_plan is not null' else '' end)
      into row_a using subject_a;
    if spec.table_name in ('profiles', 'chat_messages') then
      execute format('select to_jsonb(t) from %s t where %I = $1', target, spec.owner_column)
        into row_b using subject_b;
    else
      row_b := row_a || jsonb_build_object(spec.owner_column, subject_b);
      if spec.key_column <> spec.owner_column then
        row_b := row_b || jsonb_build_object(spec.key_column, gen_random_uuid());
      end if;
      if spec.table_name = 'medication_logs' then
        row_b := row_b || '{"medication_id":"00000000-0000-0000-0000-000000000104"}';
      end if;
      execute format('insert into %s (%s) select %s from jsonb_populate_record(null::%s, $1)',
                     target, writable_columns, writable_columns, target)
        using row_b;
    end if;
    if row_a is null or row_b is null then
      raise exception 'Missing two-owner fixture for %', target;
    end if;
    update patient_cases c set samples = jsonb_build_array(row_a, row_b), insert_columns = writable_columns
      where c.table_name = spec.table_name;
  end loop;
end
$$;
grant select on patient_cases to anon, authenticated;

set local role anon;
do $$
declare
  spec record;
begin
  for spec in select table_name from patient_cases loop
    begin
      execute format('select 1 from public.%I', spec.table_name);
      raise exception 'Anonymous access to %', spec.table_name;
    exception when insufficient_privilege then null;
    end;
  end loop;
  begin
    perform public.delete_legacy_ai_chats();
    raise exception 'Anonymous execution of chat cleanup';
  exception when insufficient_privilege then null;
  end;
end
$$;

set local role authenticated;
do $$
declare
  subjects constant uuid[] := array[
    '00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000004'
  ]::uuid[];
  spec record;
  side integer;
  target regclass;
  predicate text;
  operation text;
  statement text;
  count_rows integer;
  foreign_row jsonb;
begin
  for side in 0..2 loop
    perform set_config('request.jwt.claim.sub', coalesce(subjects[side]::text, ''), true);
    for spec in select * from patient_cases loop
      target := format('public.%I', spec.table_name)::regclass;
      predicate := format('%I = $1', spec.owner_column);
      foreign_row := spec.samples -> case when side = 2 then 0 else 1 end;
      foreach operation in array array['select', 'update', 'delete'] loop
        statement := case operation
          when 'select' then format('select count(*) from %s where %s', target, predicate)
          when 'update' then format('update %s set %I = %I where %s',
                                    target, spec.owner_column, spec.owner_column, predicate)
          else format('delete from %s where %s', target, predicate)
        end;
        begin
          if operation = 'select' then
            execute statement into count_rows using (foreign_row ->> spec.owner_column)::uuid;
          else
            execute statement using (foreign_row ->> spec.owner_column)::uuid;
            get diagnostics count_rows = row_count;
          end if;
          if operation <> all(spec.allowed) or count_rows <> 0 then
            raise exception 'Cross-owner % succeeded on %', operation, target;
          end if;
        exception when insufficient_privilege then
          if operation = any(spec.allowed) then raise; end if;
        end;
      end loop;
      if side <> 0 and 'select' = any(spec.allowed) then
        execute format('select count(*) from %s where %s', target, predicate)
          into count_rows using subjects[side];
        if count_rows < 1 then raise exception 'Owner cannot read %', target; end if;
      end if;

      statement := format('insert into %s (%s) select %s from jsonb_populate_record(null::%s, $1)',
                          target, spec.insert_columns, spec.insert_columns, target);
      begin
        execute statement using foreign_row;
        raise exception 'Cross-owner insert succeeded on %', target;
      exception when insufficient_privilege then null;
      end;
      begin
        execute statement || ' on conflict do nothing' using foreign_row;
        raise exception 'Cross-owner upsert (ignore) succeeded on %', target;
      exception when insufficient_privilege then null;
      end;
      if spec.key_column is not null then
        statement := statement || format(' on conflict (%I) do update set %I = excluded.%I',
                                         spec.key_column, spec.owner_column, spec.owner_column);
        begin
          execute statement using foreign_row;
          raise exception 'Cross-owner upsert (merge) succeeded on %', target;
        exception when insufficient_privilege then null;
        end;
        if side <> 0 and spec.owner_column <> spec.key_column then
          begin
            execute statement using
              foreign_row || jsonb_build_object(spec.owner_column, subjects[side]);
            raise exception 'Upsert against a foreign row key succeeded on %', target;
          exception when insufficient_privilege then null;
          end;
        end if;
      end if;

      if side <> 0 and 'update' = any(spec.allowed) then
        begin
          execute format('update %s set %I = $2 where %s', target, spec.owner_column, predicate)
            using subjects[side], (foreign_row ->> spec.owner_column)::uuid;
          raise exception 'Owner transfer succeeded on %', target;
        exception when insufficient_privilege then null;
        end;
      end if;
    end loop;
  end loop;

  perform set_config('request.jwt.claim.sub', subjects[1]::text, true);
  begin
    insert into public.medication_logs (user_id, medication_id)
      values (auth.uid(), '00000000-0000-0000-0000-000000000104');
    raise exception 'Own dose log accepted a foreign medication';
  exception when foreign_key_violation then null;
  end;
  begin
    insert into public.wearable_samples (user_id, metric, value, device, recorded_at)
    values (subjects[2], 'heart_rate', 73, 'apple_health', '2026-11-24 08:00:00+00')
    on conflict (user_id, metric, device, recorded_at) do nothing;
    raise exception 'Wearable import accepted a foreign owner';
  exception when insufficient_privilege then null;
  end;

  delete from public.ai_processing_consents;
  get diagnostics count_rows = row_count;
  if count_rows <> 1 then raise exception 'Consent deletion was not limited to one owner'; end if;
  if to_regclass('public.chat_messages') is not null then
    if public.delete_legacy_ai_chats() <> 1 or public.delete_legacy_ai_chats() <> 0 then
      raise exception 'Chat deletion was not limited to one owner';
    end if;
  else
    if public.delete_legacy_ai_chats() <> 0 then raise exception 'Fresh cleanup returned rows'; end if;
  end if;
  perform set_config('request.jwt.claim.sub', subjects[2]::text, true);
  if (select count(*) from public.ai_processing_consents) <> 1 then
    raise exception 'Consent deletion affected the other account';
  end if;
  if to_regclass('public.chat_messages') is not null and public.delete_legacy_ai_chats() <> 1 then
    raise exception 'Chat deletion affected the other account';
  end if;
end
$$;

reset role;
-- Parent removal and cascading effects are tested as the synthetic Auth admin.
do $$
begin
  if to_regclass('public.chat_messages') is not null then
    insert into public.chat_messages (user_id, content) values
      ('00000000-0000-0000-0000-000000000003', 'Retained chat'),
      ('00000000-0000-0000-0000-000000000004', 'Cascaded chat');
  end if;
end
$$;
set local role h1_auth_admin;
delete from auth.users where id = '00000000-0000-0000-0000-000000000004';
reset role;
do $$
declare
  spec record;
  remaining integer;
begin
  for spec in select * from patient_cases loop
    execute format('select count(*) from public.%I where %I = $1', spec.table_name, spec.owner_column)
      into remaining using '00000000-0000-0000-0000-000000000004'::uuid;
    if remaining <> 0 then raise exception 'Deleted owner still has % rows', spec.table_name; end if;
  end loop;
  if not exists (select from public.medications where id = '00000000-0000-0000-0000-000000000103')
     or not exists (select from public.medication_logs
                    where medication_id = '00000000-0000-0000-0000-000000000103')
     or not exists (select from public.lab_results where user_id = '00000000-0000-0000-0000-000000000003')
     or not exists (select from public.emergency_contacts where user_id = '00000000-0000-0000-0000-000000000003') then
    raise exception 'Parent removal affected the other account';
  end if;
  if to_regclass('public.chat_messages') is not null then
    if not exists (select from public.chat_messages where content = 'Retained chat') then
      raise exception 'Parent removal affected the other account chats';
    end if;
  end if;
end
$$;
rollback;
