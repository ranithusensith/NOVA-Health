set role h1_auth_admin;
insert into auth.users values
  ('00000000-0000-0000-0000-000000000001', '{"full_name":"Original Name"}'),
  ('00000000-0000-0000-0000-000000000002', '{"full_name":"Missing Profile"}');
reset role;

set role h1_migration_owner;
create table public.profiles (id uuid primary key, full_name text);
insert into public.profiles values ('00000000-0000-0000-0000-000000000001', 'Edited Name');
alter table public.profiles enable row level security;
create policy legacy_profile_select on public.profiles for select to authenticated using (true);
create policy legacy_profile_update on public.profiles for update to authenticated
  using (true) with check (full_name <> 'Blocked by legacy policy');

create table public.medications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  name text not null,
  dosage text,
  times text[] not null,
  start_date date,
  end_date date,
  source text not null default 'manual',
  status text not null default 'confirmed'
);
insert into public.medications (id, user_id, name, times, start_date) values
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000001',
   'Legacy medication', array['08:00'], '2026-11-01');

create table public.medication_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  medication_id uuid not null references public.medications (id),
  taken_at timestamptz not null default now()
);
insert into public.medication_logs (user_id, medication_id) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000101');

create function public.legacy_create_profile() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name');
  return new;
end
$$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.legacy_create_profile();

create table public.chat_messages (user_id uuid not null, content text not null);
alter table public.chat_messages enable row level security;
create policy legacy_chat_select on public.chat_messages for select to authenticated
  using (user_id = (select auth.uid()));
insert into public.chat_messages values
  ('00000000-0000-0000-0000-000000000001', 'First synthetic chat'),
  ('00000000-0000-0000-0000-000000000002', 'Second synthetic chat');
reset role;
