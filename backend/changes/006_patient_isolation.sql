-- Apply after H1. Keep existing policies and allowed grants, including stricter ones.
begin;

do $$
declare
  spec record;
  target_table regclass;
  column_names text;
  operation text;
begin
  for spec in
    select * from (values
      ('profiles', array['select', 'update']),
      ('allergies', array['select', 'insert', 'delete']),
      ('medications', array['select', 'insert', 'update']),
      ('medication_logs', array['select', 'insert', 'delete']),
      ('water_logs', array['select', 'insert']),
      ('sleep_logs', array['select', 'insert']),
      ('mood_logs', array['select', 'insert']),
      ('meal_logs', array['select', 'insert']),
      ('symptom_logs', array['select']),
      ('wearable_samples', array['select', 'insert', 'delete']),
      ('period_logs', array['select', 'insert', 'update', 'delete']),
      ('emergency_contacts', array['select', 'insert', 'delete']),
      ('audit_log', array['insert']),
      ('lab_results', array['select', 'insert', 'update', 'delete']),
      ('ai_processing_consents', array['select', 'insert', 'update', 'delete']),
      ('chat_messages', array[]::text[])
    ) as tables(table_name, allowed)
  loop
    target_table := to_regclass(format('public.%I', spec.table_name));
    if spec.table_name = 'chat_messages' and target_table is null then
      continue;
    end if;

    select string_agg(quote_ident(attname), ', ' order by attnum)
      into column_names
      from pg_attribute
      where attrelid = target_table and attnum > 0 and not attisdropped;

    -- REVOKE on the table alone leaves any column-level ACLs in place.
    execute format('revoke all on %s from public, anon', target_table);
    execute format('revoke all (%s) on %s from public, anon', column_names, target_table);
    execute format('revoke truncate, references, trigger on %s from authenticated', target_table);
    execute format('revoke references (%s) on %s from authenticated', column_names, target_table);
    foreach operation in array array['select', 'insert', 'update', 'delete']
    loop
      if operation <> all(spec.allowed) then
        execute format('revoke %s on %s from authenticated', operation, target_table);
        if operation <> 'delete' then
          execute format('revoke %s (%s) on %s from authenticated', operation, column_names, target_table);
        end if;
      end if;
    end loop;
  end loop;
end
$$;

-- The only application access to old chat history is the account-scoped
-- cleanup RPC. Retain an ownership boundary even if a grant is added later.
do $$
begin
  if to_regclass('public.chat_messages') is not null then
    alter table public.chat_messages enable row level security;
    drop policy if exists nova_account_boundary on public.chat_messages;
    create policy nova_account_boundary on public.chat_messages as restrictive for all to public
      using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
  end if;
end
$$;

-- CREATE TABLE IF NOT EXISTS in 002 and 004 does not repair a pre-existing
-- table without its owner FK. Preserve any equivalent validated foreign key.
do $$
declare
  child_table regclass;
  parent_table regclass;
  spec record;
begin
  for spec in
    select * from (values
      ('public.lab_results', 'public.profiles'),
      ('public.ai_processing_consents', 'auth.users'),
      ('public.chat_messages', 'auth.users')
    ) as keys(child_name, parent_name)
  loop
    child_table := to_regclass(spec.child_name);
    if child_table is null then
      continue;
    end if;
    parent_table := spec.parent_name::regclass;
    if not exists (
      select from pg_constraint fk
      join pg_attribute child on child.attrelid = fk.conrelid and array[child.attnum] = fk.conkey
      join pg_attribute parent on parent.attrelid = fk.confrelid and array[parent.attnum] = fk.confkey
      where fk.contype = 'f' and fk.convalidated
        and fk.conrelid = child_table and child.attname = 'user_id'
        and fk.confrelid = parent_table and parent.attname = 'id'
    ) then
      execute format(
        'alter table %s add constraint nova_owner_fk foreign key (user_id) references %s (id) on delete cascade',
        child_table, parent_table
      );
    end if;
  end loop;
end
$$;

-- A legacy immediate medication-ID-only FK can run before the owner-aware
-- cascade and block account deletion. Drop it only where that cascade exists.
do $$
declare
  old_fk record;
begin
  if not exists (
    select from pg_constraint
    where conrelid = 'public.medication_logs'::regclass
      and confrelid = 'public.medications'::regclass
      and contype = 'f' and convalidated and confdeltype = 'c'
      and conkey = array[
        (select attnum from pg_attribute where attrelid = conrelid and attname = 'user_id'),
        (select attnum from pg_attribute where attrelid = conrelid and attname = 'medication_id')
      ]
      and confkey = array[
        (select attnum from pg_attribute where attrelid = confrelid and attname = 'user_id'),
        (select attnum from pg_attribute where attrelid = confrelid and attname = 'id')
      ]
  ) then
    return;
  end if;

  for old_fk in
    select conname from pg_constraint
    where conrelid = 'public.medication_logs'::regclass
      and confrelid = 'public.medications'::regclass
      and contype = 'f' and confdeltype = 'a' and confupdtype = 'a' and not condeferrable
      and conkey = array[(select attnum from pg_attribute where attrelid = conrelid and attname = 'medication_id')]
      and confkey = array[(select attnum from pg_attribute where attrelid = confrelid and attname = 'id')]
  loop
    execute format('alter table public.medication_logs drop constraint %I', old_fk.conname);
  end loop;
end
$$;

commit;
