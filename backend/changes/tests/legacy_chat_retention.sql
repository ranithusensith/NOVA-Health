-- Disposable databases only. Fixtures and deletes are rolled back.
begin;

insert into auth.users (id, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000001101', '{}'),
  ('00000000-0000-0000-0000-000000001102', '{}');

set local role h1_migration_owner;
do $$
begin
  if has_function_privilege('anon', 'public.prune_legacy_ai_chats()', 'execute')
    or has_function_privilege('authenticated', 'public.prune_legacy_ai_chats()', 'execute') then
    raise exception 'Client can run global retention';
  end if;
  if to_regclass('public.chat_messages') is null then
    if public.prune_legacy_ai_chats() <> 0 then
      raise exception 'Fresh database reported deleted chats';
    end if;
    create table public.chat_messages (user_id uuid not null, content text not null);
    -- Match the prior migration's locked-down legacy table in the fresh fixture.
    revoke all on public.chat_messages from anon, authenticated;
    alter table public.chat_messages enable row level security;
  end if;
end
$$;

insert into public.chat_messages (user_id, content) values
  ('00000000-0000-0000-0000-000000001101', 'Synthetic first account message'),
  ('00000000-0000-0000-0000-000000001102', 'Synthetic second account message');

set local role anon;
do $$
begin
  begin
    perform public.delete_legacy_ai_chats();
    raise exception 'Anonymous deletion was allowed';
  exception when insufficient_privilege then null;
  end;
end
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '', true);
do $$
begin
  begin
    perform public.delete_legacy_ai_chats();
    raise exception 'Deletion without a JWT subject was allowed';
  exception when insufficient_privilege then null;
  end;
end
$$;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000001101', true);
do $$
begin
  begin
    perform public.prune_legacy_ai_chats();
    raise exception 'Authenticated account could run global retention';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.chat_messages;
    raise exception 'Direct client deletion was allowed';
  exception when insufficient_privilege then null;
  end;
  if public.delete_legacy_ai_chats() <> 1 then
    raise exception 'Authenticated cleanup did not remove one own row';
  end if;
  if public.delete_legacy_ai_chats() <> 0 then
    raise exception 'Repeated authenticated cleanup was not empty';
  end if;
end
$$;

set local role h1_migration_owner;
do $$
begin
  if not exists (select from public.chat_messages
      where user_id = '00000000-0000-0000-0000-000000001102') then
    raise exception 'First account deleted the second account chat';
  end if;
  if public.prune_legacy_ai_chats() < 1 then
    raise exception 'Undated legacy rows were not removed';
  end if;
  if exists (select from public.chat_messages) then
    raise exception 'Undated legacy rows remain after retention';
  end if;
end
$$;

alter table public.chat_messages add column created_at timestamptz;
insert into public.chat_messages (user_id, content, created_at) values
  ('00000000-0000-0000-0000-000000001101', 'Synthetic expired',
    statement_timestamp() - interval '31 days'),
  ('00000000-0000-0000-0000-000000001102', 'Synthetic recent',
    statement_timestamp() - interval '29 days'),
  ('00000000-0000-0000-0000-000000001102', 'Synthetic missing date', null);

do $$
begin
  if public.prune_legacy_ai_chats() <> 2 then
    raise exception 'Retention did not remove expired and null timestamp rows';
  end if;
  if public.prune_legacy_ai_chats() <> 0
    or (select count(*) from public.chat_messages where content = 'Synthetic recent') <> 1 then
    raise exception 'Retention did not preserve the recent row';
  end if;
end
$$;

alter table public.chat_messages alter column created_at type timestamp
  using created_at at time zone 'UTC';
set local time zone 'Pacific/Honolulu';
insert into public.chat_messages (user_id, content, created_at) values
  ('00000000-0000-0000-0000-000000001101', 'Synthetic UTC expired',
    (statement_timestamp() - interval '31 days') at time zone 'UTC');
do $$
begin
  if public.prune_legacy_ai_chats() <> 1
    or (select count(*) from public.chat_messages where content = 'Synthetic recent') <> 1 then
    raise exception 'Timestamp without time zone did not use UTC';
  end if;
end
$$;

-- Unknown date formats must prompt schema review rather than silently deleting.
alter table public.chat_messages alter column created_at type text;
do $$
begin
  begin
    perform public.prune_legacy_ai_chats();
    raise exception 'Retention accepted an unsupported timestamp type' using errcode = 'XX000';
  exception when raise_exception then
    if sqlerrm <> 'Unsupported legacy chat timestamp type' then raise; end if;
  end;
  if (select count(*) from public.chat_messages) <> 1 then
    raise exception 'Unsupported type led to deletion';
  end if;
end
$$;

rollback;
