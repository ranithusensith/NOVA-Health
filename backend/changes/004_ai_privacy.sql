-- Apply in Supabase before enabling C4 external AI. Existing users start opted out.
create table if not exists public.ai_processing_consents (
  user_id uuid primary key references auth.users (id) on delete cascade,
  disclosure_version text not null,
  consented_at timestamptz not null default now()
);

alter table public.ai_processing_consents enable row level security;
drop policy if exists "own ai consent" on public.ai_processing_consents;
create policy "own ai consent" on public.ai_processing_consents
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
revoke all on public.ai_processing_consents from public, anon;
grant select, insert, update, delete on public.ai_processing_consents to authenticated;

-- The migration owner can delete legacy rows even on installations whose old
-- policies allowed only reads and inserts. The RPC scopes all deletes to auth.uid().
create or replace function public.delete_legacy_ai_chats()
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  removed integer := 0;
begin
  if auth.uid() is null then
    raise insufficient_privilege;
  end if;
  if to_regclass('public.chat_messages') is not null then
    delete from public.chat_messages where user_id = auth.uid();
    get diagnostics removed = row_count;
  end if;
  return removed;
end
$$;
revoke all on function public.delete_legacy_ai_chats() from public, anon;
grant execute on function public.delete_legacy_ai_chats() to authenticated;
