-- NOVA Health: change 002 - lab results saved from scanned reports
-- Run once in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- Safe to run more than once.

create table if not exists public.lab_results (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  test_name   text not null,
  value       numeric,
  value_text  text,                 -- non-numeric results, e.g. 'Negative'
  unit        text,
  ref_low     numeric,
  ref_high    numeric,
  flag        text not null default 'unknown' check (flag in ('low', 'normal', 'high', 'unknown')),
  report_type text,
  reported_on date,
  source      text not null default 'scan',
  created_at  timestamptz not null default now()
);

create index if not exists lab_results_user_date
  on public.lab_results (user_id, reported_on desc, created_at desc);

alter table public.lab_results enable row level security;

drop policy if exists "own rows" on public.lab_results;
create policy "own rows" on public.lab_results
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.lab_results to authenticated;
