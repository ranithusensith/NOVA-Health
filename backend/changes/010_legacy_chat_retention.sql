begin;

-- Only the database owner operating the migration can run this maintenance.
-- The existing authenticated delete_legacy_ai_chats() RPC remains account-scoped.
create or replace function public.prune_legacy_ai_chats()
returns bigint
language plpgsql security invoker
set search_path = ''
as $$
declare
  chats regclass := pg_catalog.to_regclass('public.chat_messages');
  date_type regtype;
  cutoff timestamptz := statement_timestamp() - interval '720 hours';
  removed bigint;
begin
  if chats is null then
    return 0;
  end if;

  select atttypid into date_type
  from pg_catalog.pg_attribute
  where attrelid = chats and attname = 'created_at'
    and attnum > 0 and not attisdropped;

  if date_type = 'pg_catalog.timestamptz'::regtype then
    delete from public.chat_messages where created_at is null or created_at <= cutoff;
  elsif date_type = 'pg_catalog.timestamp'::regtype then
    delete from public.chat_messages
      where created_at is null or created_at <= (cutoff at time zone 'UTC');
  elsif date_type is null then
    -- The undated legacy schema cannot demonstrate that any row is recent.
    delete from public.chat_messages;
  else
    raise exception 'Unsupported legacy chat timestamp type';
  end if;
  get diagnostics removed = row_count;
  return removed;
end
$$;

revoke all on function public.prune_legacy_ai_chats() from public;
-- Remove role-specific grants from default privileges or a previous installation.
do $$
declare
  grantee name;
begin
  for grantee in
    select r.rolname from pg_catalog.pg_proc p
    cross join lateral pg_catalog.aclexplode(p.proacl) a
    join pg_catalog.pg_roles r on r.oid = a.grantee
    where p.oid = 'public.prune_legacy_ai_chats()'::regprocedure
      and a.grantee <> p.proowner
  loop
    execute format('revoke all on function public.prune_legacy_ai_chats() from %I cascade', grantee);
  end loop;
end
$$;

commit;
