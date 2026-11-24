-- Harden access to the tables added by 002 and 004 without rewriting those migrations.
begin;

do $$
declare
  target_table regclass;
begin
  foreach target_table in array array['public.lab_results'::regclass, 'public.ai_processing_consents'::regclass]
  loop
    execute format('revoke all on %s from public, anon', target_table);
    execute format('revoke truncate, references, trigger on %s from authenticated', target_table);
    execute format('alter table %s enable row level security', target_table);
    execute format('drop policy if exists nova_account_boundary on %s', target_table);
    execute format(
      'create policy nova_account_boundary on %s as restrictive for all to public
       using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)',
      target_table
    );
  end loop;
end
$$;

commit;
