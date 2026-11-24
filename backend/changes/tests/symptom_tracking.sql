-- Disposable database only. Run once before 013 and once after 013.
\if :{?p11_before_migration}
insert into auth.users (id, raw_user_meta_data) values
  ('a1300000-0000-0000-0000-000000000001', '{"full_name":"Synthetic Symptom Owner"}'),
  ('a1300000-0000-0000-0000-000000000002', '{"full_name":"Synthetic Other Owner"}');
insert into public.symptom_logs (id, user_id, name, severity, status, started_at)
values ('a1300000-0000-0000-0000-000000000010', 'a1300000-0000-0000-0000-000000000001',
        'Synthetic prior entry', 'unspecified', 'legacy', '2026-01-01T10:00:00Z');
\else
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1300000-0000-0000-0000-000000000001', true);
do $$
declare
  entry_id constant uuid := 'a1300000-0000-0000-0000-000000000011';
  other_id constant uuid := 'a1300000-0000-0000-0000-000000000002';
  original_revision uuid;
  edited_revision uuid;
begin
  if not exists (
    select from public.symptom_logs where name = 'Synthetic prior entry'
      and severity = 'unspecified' and status = 'legacy' and notes is null and revision is not null
  ) then raise exception 'Legacy symptom was altered or hidden'; end if;

  insert into public.symptom_logs (id, user_id, name, severity, started_at, notes)
  values (entry_id, auth.uid(), 'Synthetic new entry', 'mild', '2026-02-02T09:00:00+05:30', 'Synthetic note')
  returning revision into original_revision;
  if not exists (select from public.symptom_logs where id = entry_id and status = 'active'
                 and started_at = '2026-02-02T03:30:00Z' and notes = 'Synthetic note')
  then raise exception 'Owner could not read created values'; end if;

  update public.symptom_logs set name = 'Synthetic corrected entry', status = 'resolved',
    severity = null, notes = null, started_at = '2026-02-01T09:00:00Z'
  where id = entry_id and revision = original_revision returning revision into edited_revision;
  if edited_revision is null or original_revision = edited_revision then
    raise exception 'Edit did not replace its revision';
  end if;
  if not exists (select from public.symptom_logs where id = entry_id and name = 'Synthetic corrected entry'
                 and status = 'resolved' and severity is null and notes is null
                 and started_at = '2026-02-01T09:00:00Z')
  then raise exception 'Owner could not read edited values'; end if;

  update public.symptom_logs set status = 'active' where id = entry_id and revision = original_revision;
  if found then raise exception 'A stale edit overwrote the current revision'; end if;
  delete from public.symptom_logs where id = entry_id and revision = original_revision;
  if found then raise exception 'A stale deletion removed the current revision'; end if;

  begin
    insert into public.symptom_logs (user_id, name) values (other_id, 'Synthetic wrong owner');
    raise exception 'Created a symptom for another account';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.symptom_logs set user_id = other_id where id = entry_id;
    raise exception 'Owner was transferable';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.symptom_logs set revision = original_revision where id = entry_id;
    raise exception 'Revision was client-writable';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.symptom_logs set status = 'unknown' where id = entry_id;
    raise exception 'Invalid status accepted';
  exception when check_violation then null;
  end;
  begin
    update public.symptom_logs set severity = 'unknown' where id = entry_id;
    raise exception 'Invalid severity accepted';
  exception when check_violation then null;
  end;
  begin
    update public.symptom_logs set notes = repeat('a', 1001) where id = entry_id;
    raise exception 'Oversize notes accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.symptom_logs (user_id, name, started_at)
    values (auth.uid(), 'Synthetic invalid onset', clock_timestamp() + interval '1 day');
    raise exception 'Future onset accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.symptom_logs (user_id, name) values (auth.uid(), '   ');
    raise exception 'Blank symptom name accepted';
  exception when check_violation then null;
  end;
end
$$;

select set_config('request.jwt.claim.sub', 'a1300000-0000-0000-0000-000000000002', true);
do $$
begin
  if exists (select from public.symptom_logs) then raise exception 'Other account could read history'; end if;
  update public.symptom_logs set name = 'Synthetic tampering';
  if found then raise exception 'Other account could edit history'; end if;
  delete from public.symptom_logs;
  if found then raise exception 'Other account could delete history'; end if;
end
$$;

set local role anon;
do $$
begin
  begin
    perform notes from public.symptom_logs;
    raise exception 'Anonymous account could read symptom notes';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.symptom_logs (name, user_id) values ('Synthetic anonymous', auth.uid());
    raise exception 'Anonymous account could create symptoms';
  exception when insufficient_privilege then null;
  end;
end
$$;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1300000-0000-0000-0000-000000000001', true);
do $$
begin
  delete from public.symptom_logs where id = 'a1300000-0000-0000-0000-000000000011';
  if not found then raise exception 'Owner could not delete its current entry'; end if;
  if exists (select from public.symptom_logs where id = 'a1300000-0000-0000-0000-000000000011') then
    raise exception 'Deleted entry was still in history';
  end if;
end
$$;
rollback;
\endif
