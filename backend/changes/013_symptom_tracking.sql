-- Open owner-scoped symptom writes after the read-only baseline and H2 hardening.
begin;

alter table public.symptom_logs
  add column if not exists notes text,
  add column if not exists revision uuid not null default gen_random_uuid();

-- Earlier imports may use unknown severity/status values. Preserve their rows.
alter table public.symptom_logs
  add constraint nova_symptom_name check (
    name is not null and char_length(name) <= 120 and name ~ '[^[:space:]]' and name !~ '[[:cntrl:]]'
  ) not valid,
  add constraint nova_symptom_severity check (severity in ('mild', 'moderate', 'severe')) not valid,
  add constraint nova_symptom_status check (status is not null and status in ('active', 'resolved')) not valid,
  add constraint nova_symptom_notes_length check (char_length(notes) <= 1000) not valid;

create function public.nova_prepare_symptom_write()
returns trigger language plpgsql set search_path = pg_catalog
as $$
begin
  if new.started_at is null or not isfinite(new.started_at) or new.started_at > clock_timestamp() then
    raise check_violation using message = 'Choose an onset date and time that has passed';
  end if;
  new.revision := gen_random_uuid();
  return new;
end
$$;
revoke all on function public.nova_prepare_symptom_write() from public, anon, authenticated;
create trigger nova_prepare_symptom_write
  before insert or update on public.symptom_logs
  for each row execute function public.nova_prepare_symptom_write();

-- The restrictive owner policy from 001 remains in effect for all commands.
create policy nova_symptom_insert on public.symptom_logs for insert to authenticated
  with check ((select auth.uid()) = user_id);
create policy nova_symptom_update on public.symptom_logs for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy nova_symptom_delete on public.symptom_logs for delete to authenticated
  using ((select auth.uid()) = user_id);

grant insert (id, user_id, name, severity, status, started_at, notes) on public.symptom_logs to authenticated;
grant update (name, severity, status, started_at, notes) on public.symptom_logs to authenticated;
grant delete on public.symptom_logs to authenticated;
-- Legacy deployments can retain a column-scoped read grant after H2.
grant select (notes, revision) on public.symptom_logs to authenticated;

commit;
