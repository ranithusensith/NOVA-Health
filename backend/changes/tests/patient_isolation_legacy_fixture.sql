-- Only for disposable legacy copies, after 005 and before 006.
set role h1_migration_owner;
create policy legacy_chat_all on public.chat_messages for all to authenticated
  using (true) with check (true);
grant select (content) on public.chat_messages to public;
grant update (content) on public.chat_messages to anon;
grant delete on public.profiles to authenticated;
grant insert (id, full_name) on public.profiles to authenticated;
alter table public.lab_results drop constraint lab_results_user_id_fkey;
alter table public.ai_processing_consents drop constraint ai_processing_consents_user_id_fkey;
reset role;
