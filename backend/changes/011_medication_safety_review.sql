-- Run after 010. Install pgcrypto as a database administrator if it is absent.
begin;

create extension if not exists pgcrypto;

alter table public.medications
  add column if not exists review_revision uuid not null default gen_random_uuid();

create table if not exists public.nova_medication_signing_key (
  singleton boolean primary key default true check (singleton),
  signing_key bytea not null check (octet_length(signing_key) = 32)
);
alter table public.nova_medication_signing_key enable row level security;
revoke all on public.nova_medication_signing_key from public, anon, authenticated;

-- Every change to a rule input invalidates an in-flight review for that account.
create table if not exists public.nova_medication_context_versions (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  version uuid not null default gen_random_uuid()
);
alter table public.nova_medication_context_versions enable row level security;
revoke all on public.nova_medication_context_versions from public, anon, authenticated;

create or replace function public.nova_change_medication_context()
returns trigger language plpgsql security definer set search_path = pg_catalog
as $$
begin
  if TG_TABLE_NAME = 'profiles' then
    if TG_OP = 'INSERT' then
      insert into public.nova_medication_context_versions (user_id) values (new.id);
    else
      update public.nova_medication_context_versions set version = gen_random_uuid() where user_id = new.id;
    end if;
  else
    if TG_OP in ('UPDATE', 'DELETE') then
      update public.nova_medication_context_versions set version = gen_random_uuid() where user_id = old.user_id;
    end if;
    if TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and new.user_id is distinct from old.user_id) then
      update public.nova_medication_context_versions set version = gen_random_uuid() where user_id = new.user_id;
    end if;
  end if;
  return null;
end
$$;
revoke all on function public.nova_change_medication_context() from public, anon, authenticated;

drop trigger if exists nova_medication_context_profile_insert on public.profiles;
create trigger nova_medication_context_profile_insert after insert on public.profiles
  for each row execute function public.nova_change_medication_context();
drop trigger if exists nova_medication_context_profile_update on public.profiles;
create trigger nova_medication_context_profile_update after update on public.profiles
  for each row when (old.conditions is distinct from new.conditions)
  execute function public.nova_change_medication_context();
drop trigger if exists nova_medication_context_allergies on public.allergies;
create trigger nova_medication_context_allergies after insert or update or delete on public.allergies
  for each row execute function public.nova_change_medication_context();
drop trigger if exists nova_medication_context_medications on public.medications;
create trigger nova_medication_context_medications after insert or update or delete on public.medications
  for each row execute function public.nova_change_medication_context();
insert into public.nova_medication_context_versions (user_id)
select id from public.profiles on conflict (user_id) do nothing;

create or replace function public.medication_safety_version()
returns uuid language sql stable security definer set search_path = pg_catalog
as $$
  select version from public.nova_medication_context_versions where user_id = auth.uid()
$$;
revoke all on function public.medication_safety_version() from public, anon, authenticated;
grant execute on function public.medication_safety_version() to authenticated;

do $$
declare
  columns text;
begin
  select string_agg(quote_ident(attname), ', ' order by attnum) into columns
  from pg_attribute
  where attrelid = 'public.medications'::regclass and attnum > 0 and not attisdropped;
  revoke insert, update on public.medications from public, anon, authenticated;
  execute format('revoke insert (%1$s), update (%1$s) on public.medications from public, anon, authenticated', columns);
end
$$;

-- Retain the owner-scoped stop operation used by Flutter and older clients.
grant update (status, end_date) on public.medications to authenticated;

create or replace function public.nova_guard_medication_update()
returns trigger language plpgsql set search_path = pg_catalog
as $$
begin
  if current_user in ('authenticated', 'anon')
      and (old.status is distinct from 'confirmed' or new.status is distinct from 'ended') then
    raise insufficient_privilege using message = 'Medication changes require safety review';
  end if;
  new.review_revision := gen_random_uuid();
  return new;
end
$$;
revoke all on function public.nova_guard_medication_update() from public, anon, authenticated;

drop trigger if exists nova_guard_medication_update on public.medications;
create trigger nova_guard_medication_update
  before update on public.medications for each row
  execute function public.nova_guard_medication_update();

create or replace function public.save_reviewed_medications(review_payload text, review_signature text)
returns boolean language plpgsql security definer set search_path = pg_catalog
as $$
declare
  account_id uuid := auth.uid();
  payload jsonb;
  reviewed_rows jsonb;
  expected_revision uuid;
  current_context_version uuid;
  key bytea;
  crypto_schema name;
  expected_signature bytea;
  expires bigint;
  changed integer;
begin
  if account_id is null or review_payload is null or octet_length(review_payload) > 131072
      or review_signature is null or review_signature !~ '^[0-9a-f]{64}$' then
    raise insufficient_privilege using message = 'Medication review authorization required';
  end if;

  select signing_key into key from public.nova_medication_signing_key where singleton;
  if key is null then
    raise insufficient_privilege using message = 'Medication review authorization unavailable';
  end if;
  select n.nspname into strict crypto_schema
  from pg_extension e join pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';

  -- Supabase and standalone PostgreSQL may install pgcrypto in different schemas.
  execute format('select %I.hmac($1, $2, ''sha256'')', crypto_schema)
    into expected_signature using convert_to('medication-write:' || review_payload, 'UTF8'), key;
  if sha256(expected_signature) <> sha256(decode(review_signature, 'hex')) then
    raise insufficient_privilege using message = 'Medication review authorization required';
  end if;

  payload := review_payload::jsonb;
  reviewed_rows := payload->'rows';
  expected_revision := (payload->>'expected_revision')::uuid;
  expires := (payload->>'expires')::bigint;
  if (payload->>'account')::uuid is distinct from account_id
      or expires is null or expires <= extract(epoch from clock_timestamp())
      or jsonb_typeof(reviewed_rows) is distinct from 'array' then
    raise insufficient_privilege using message = 'Medication review authorization required';
  end if;
  if jsonb_array_length(reviewed_rows) not between 1 and 10 or exists (
    select 1 from jsonb_array_elements(reviewed_rows) as row_data
    where (row_data->>'user_id')::uuid is distinct from account_id
      or row_data->>'status' is distinct from 'confirmed'
  ) then
    raise insufficient_privilege using message = 'Medication review authorization required';
  end if;

  -- Serialize reviewed writes against changes to the account's safety inputs.
  select version into current_context_version from public.nova_medication_context_versions
  where user_id = account_id for update;
  if current_context_version is null
      or current_context_version is distinct from (payload->>'context_version')::uuid then
    return false;
  end if;

  if expected_revision is not null then
    if jsonb_array_length(reviewed_rows) <> 1 then
      raise insufficient_privilege using message = 'Medication review authorization required';
    end if;
    -- Match the current owner, status and revision at write time. FastAPI
    -- builds the reviewed plan from the current stored original directions.
    update public.medications as target
    set name = reviewed.name, dosage = reviewed.dosage, times = reviewed.times,
        start_date = reviewed.start_date, end_date = reviewed.end_date,
        reminders_enabled = reviewed.reminders_enabled, prescription_plan = reviewed.prescription_plan
    from jsonb_populate_recordset(null::public.medications, reviewed_rows) as reviewed
    where target.id = reviewed.id and target.user_id = account_id
      and target.status = 'confirmed' and target.review_revision = expected_revision;
    get diagnostics changed = row_count;
    return changed = 1;
  end if;

  insert into public.medications
    (id, user_id, name, dosage, times, start_date, end_date, source, status, prescription_plan, reminders_enabled)
  select id, account_id, name, dosage, times, start_date, end_date, source, 'confirmed',
         prescription_plan, reminders_enabled
  from jsonb_populate_recordset(null::public.medications, reviewed_rows);
  return true;
end
$$;
revoke all on function public.save_reviewed_medications(text, text) from public, anon, authenticated;
grant execute on function public.save_reviewed_medications(text, text) to authenticated;

commit;
