-- Use only in a disposable PostgreSQL cluster. Supabase supplies these objects.
select 'create role anon' where not exists (select from pg_roles where rolname = 'anon') \gexec
select 'create role authenticated' where not exists (select from pg_roles where rolname = 'authenticated') \gexec
select 'create role h1_auth_admin' where not exists (select from pg_roles where rolname = 'h1_auth_admin') \gexec
select 'create role h1_migration_owner' where not exists (select from pg_roles where rolname = 'h1_migration_owner') \gexec

create schema auth authorization h1_auth_admin;
set role h1_auth_admin;
create table auth.users (
  id uuid primary key,
  raw_user_meta_data jsonb
);
create function auth.uid() returns uuid language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid
$$;
revoke all on function auth.uid() from public;
grant usage on schema auth to h1_migration_owner, anon, authenticated;
grant execute on function auth.uid() to h1_migration_owner, anon, authenticated;
grant select, trigger, references on auth.users to h1_migration_owner;
reset role;

grant usage, create on schema public to h1_migration_owner;
alter default privileges for role h1_migration_owner in schema public
  grant all on tables to anon, authenticated;
alter default privileges for role h1_migration_owner in schema public
  grant execute on functions to anon, authenticated;
