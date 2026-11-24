-- Requires the Supabase Auth schema and roles. Apply as the migration owner.
begin;

-- Install the Auth trigger before locking public tables so an in-flight signup
-- can finish first. Run after conventional legacy signup triggers by name.
create or replace function public.nova_create_health_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (
    new.id,
    case when jsonb_typeof(new.raw_user_meta_data -> 'full_name') = 'string'
      then nullif(btrim(new.raw_user_meta_data ->> 'full_name'), '')
    end
  )
  on conflict (id) do nothing;
  return new;
end
$$;

revoke all on function public.nova_create_health_profile() from public, anon, authenticated;
create or replace trigger zz_nova_create_health_profile
after insert on auth.users
for each row execute function public.nova_create_health_profile();

create table if not exists public.profiles (
  id uuid primary key,
  created_at timestamptz not null default now()
);

alter table public.profiles
  add column if not exists full_name text,
  add column if not exists birth_date date,
  add column if not exists sex text,
  add column if not exists blood_type text,
  add column if not exists height_cm numeric,
  add column if not exists weight_kg numeric,
  add column if not exists conditions text[] not null default '{}',
  add column if not exists goals text[] not null default '{}',
  add column if not exists medical_notes text,
  add column if not exists onboarding_done boolean not null default false;

create table if not exists public.allergies (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  name text not null,
  source text not null default 'user',
  status text not null default 'confirmed',
  created_at timestamptz not null default now()
);

create table if not exists public.medications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  name text not null,
  dosage text,
  times text[] not null default '{}',
  start_date date,
  end_date date,
  source text not null default 'manual',
  status text not null default 'confirmed',
  created_at timestamptz not null default now()
);

create table if not exists public.medication_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  medication_id uuid not null,
  taken_at timestamptz not null default now()
);

-- Flutter records only taken doses and omits status. FastAPI reports count it.
alter table public.medication_logs
  add column if not exists status text not null default 'taken';
alter table public.medication_logs
  alter column status set default 'taken';

create table if not exists public.water_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  amount_ml integer not null,
  logged_at timestamptz not null default now()
);

create table if not exists public.sleep_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  hours numeric not null,
  logged_at timestamptz not null default now()
);

create table if not exists public.mood_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  mood text not null check (mood in ('bad', 'low', 'ok', 'good', 'great')),
  logged_at timestamptz not null default now()
);

create table if not exists public.meal_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  description text not null,
  calories integer,
  nutrients jsonb,
  source text not null default 'manual',
  status text not null default 'confirmed',
  logged_at timestamptz not null default now()
);

create table if not exists public.symptom_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  name text not null,
  severity text,
  status text not null default 'active',
  started_at timestamptz not null default now()
);

create table if not exists public.wearable_samples (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  metric text not null,
  value numeric not null,
  device text not null default 'manual',
  context text not null default 'unknown',
  recorded_at timestamptz not null
);

create table if not exists public.period_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  start_date date not null,
  end_date date,
  flow text,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.emergency_contacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  name text not null,
  phone text not null,
  relationship text,
  created_at timestamptz not null default now()
);

create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  action text not null,
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);

-- Application filters and sort orders start with the owner. The wearable
-- import upsert requires an unconditional unique index on its conflict key.
create index if not exists nova_allergies_owner_status_name
  on public.allergies (user_id, status, name);
create unique index if not exists nova_medications_owner_id
  on public.medications (user_id, id);
create index if not exists nova_medications_owner_status_name
  on public.medications (user_id, status, name);
create index if not exists nova_medication_logs_owner_time
  on public.medication_logs (user_id, taken_at desc);
create index if not exists nova_medication_logs_owner_medication_time
  on public.medication_logs (user_id, medication_id, taken_at desc);
create index if not exists nova_water_logs_owner_time on public.water_logs (user_id, logged_at desc);
create index if not exists nova_sleep_logs_owner_time on public.sleep_logs (user_id, logged_at desc);
create index if not exists nova_mood_logs_owner_time on public.mood_logs (user_id, logged_at desc);
create index if not exists nova_meal_logs_owner_time on public.meal_logs (user_id, logged_at desc);
create index if not exists nova_symptom_logs_owner_time on public.symptom_logs (user_id, started_at desc);
create unique index if not exists nova_wearable_samples_import_key
  on public.wearable_samples (user_id, metric, device, recorded_at);
create index if not exists nova_wearable_samples_owner_metric_time
  on public.wearable_samples (user_id, metric, recorded_at desc);
create index if not exists nova_period_logs_owner_date on public.period_logs (user_id, start_date desc);
create index if not exists nova_emergency_contacts_owner_name on public.emergency_contacts (user_id, name);
create index if not exists nova_audit_log_owner_time on public.audit_log (user_id, created_at desc);

-- PostgREST uses authenticated for signed-in users, including FastAPI. Retain
-- existing RLS policies and intersect them with the owner guard. Add the
-- application policies and minimum grants where RLS was previously disabled.
do $$
declare
  spec record;
  owner_key text;
  target_table regclass;
  had_rls boolean;
  allowed_command text;
  owner_predicate text;
  policy_clause text;
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
      ('audit_log', array['insert'])
    ) as tables(table_name, commands)
  loop
    target_table := format('public.%I', spec.table_name)::regclass;
    owner_key := case when spec.table_name = 'profiles' then 'id' else 'user_id' end;
    owner_predicate := format('(select auth.uid()) = %I', owner_key);
    select relrowsecurity into had_rls from pg_class where oid = target_table;

    execute format('revoke all on %s from public, anon', target_table);
    execute format('revoke truncate, references, trigger on %s from authenticated', target_table);
    if not had_rls then
      execute format('revoke all on %s from authenticated', target_table);
      foreach allowed_command in array spec.commands loop
        execute format('grant %s on %s to authenticated', allowed_command, target_table);
        policy_clause := case when allowed_command = 'insert'
          then format('with check (%s)', owner_predicate)
          else format('using (%s)', owner_predicate)
        end;
        execute format('create policy nova_%s on %s for %s to authenticated %s',
                       allowed_command, target_table, allowed_command, policy_clause);
      end loop;
    end if;

    execute format('alter table %s enable row level security', target_table);
    execute format('drop policy if exists nova_account_boundary on %s', target_table);
    execute format(
      'create policy nova_account_boundary on %s as restrictive for all to public
       using (%s) with check (%s)',
      target_table, owner_predicate, owner_predicate
    );
  end loop;
end
$$;

-- Fill gaps only. Preserve existing account profiles, including edited names.
insert into public.profiles (id, full_name)
select u.id,
       case when jsonb_typeof(u.raw_user_meta_data -> 'full_name') = 'string'
         then nullif(btrim(u.raw_user_meta_data ->> 'full_name'), '')
       end
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id)
on conflict (id) do nothing;

-- Add missing ownership relationships to both fresh and existing tables.
-- Keep equivalent existing foreign keys, including their delete behavior.
do $$
declare
  spec record;
  child_table regclass;
  parent_table regclass;
  child_columns smallint[];
  parent_columns smallint[];
begin
  for spec in
    select * from (values
      ('public.profiles', 'id', 'auth.users', 'id'),
      ('public.allergies', 'user_id', 'public.profiles', 'id'),
      ('public.medications', 'user_id', 'public.profiles', 'id'),
      ('public.medication_logs', 'user_id,medication_id', 'public.medications', 'user_id,id'),
      ('public.water_logs', 'user_id', 'public.profiles', 'id'),
      ('public.sleep_logs', 'user_id', 'public.profiles', 'id'),
      ('public.mood_logs', 'user_id', 'public.profiles', 'id'),
      ('public.meal_logs', 'user_id', 'public.profiles', 'id'),
      ('public.symptom_logs', 'user_id', 'public.profiles', 'id'),
      ('public.wearable_samples', 'user_id', 'public.profiles', 'id'),
      ('public.period_logs', 'user_id', 'public.profiles', 'id'),
      ('public.emergency_contacts', 'user_id', 'public.profiles', 'id'),
      ('public.audit_log', 'user_id', 'public.profiles', 'id')
    ) as keys(child_name, child_keys, parent_name, parent_keys)
  loop
    child_table := spec.child_name::regclass;
    parent_table := spec.parent_name::regclass;
    select array_agg(a.attnum order by cols.position) into child_columns
      from unnest(string_to_array(spec.child_keys, ',')) with ordinality as cols(name, position)
      join pg_attribute a on a.attrelid = child_table and a.attname = cols.name;
    select array_agg(a.attnum order by cols.position) into parent_columns
      from unnest(string_to_array(spec.parent_keys, ',')) with ordinality as cols(name, position)
      join pg_attribute a on a.attrelid = parent_table and a.attname = cols.name;
    if not exists (
      select 1 from pg_constraint where contype = 'f' and convalidated
        and conrelid = child_table and confrelid = parent_table
        and conkey = child_columns and confkey = parent_columns
    ) then
      execute format(
        'alter table %s add constraint nova_owner_fk foreign key (%s) references %s (%s) on delete cascade',
        child_table, spec.child_keys, parent_table, spec.parent_keys
      );
    end if;
  end loop;
end
$$;

commit;
