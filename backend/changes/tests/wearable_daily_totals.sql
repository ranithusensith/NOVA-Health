-- Disposable database only.
begin;
insert into auth.users (id, raw_user_meta_data) values
  ('a1400000-0000-0000-0000-000000000001', '{"full_name":"Synthetic wearable owner"}'),
  ('a1400000-0000-0000-0000-000000000002', '{"full_name":"Synthetic other owner"}');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1400000-0000-0000-0000-000000000001', true);

do $$
declare
  owner uuid := auth.uid();
  data jsonb := '[{
    "metric":"steps", "local_date":"2026-03-08", "window_start":"2026-03-08T05:00:00Z",
    "window_end":"2026-03-09T04:00:00Z", "captured_at":"2026-03-08T21:00:00Z",
    "value":1200, "source":"apple_health"
  }]';
  revised jsonb;
begin
  if public.save_wearable_daily_totals(owner, data) <> 1 then raise exception 'Initial save failed'; end if;
  if public.save_wearable_daily_totals(owner, data) <> 0 then raise exception 'A retry duplicated a step total'; end if;
  revised := jsonb_set(jsonb_set(data,'{0,value}','1400'),'{0,captured_at}','"2026-03-08T22:00:00Z"');
  if public.save_wearable_daily_totals(owner, revised) <> 1 then raise exception 'Refresh failed'; end if;
  if public.save_wearable_daily_totals(owner, data) <> 0 then raise exception 'Old import overrode recent data'; end if;
  if not exists (select from public.wearable_daily_totals where value = 1400) then raise exception 'Revised total unavailable'; end if;
  if (select count(*) from public.wearable_daily_totals) <> 1 then raise exception 'Duplicate total'; end if;

  -- A different calendar window is retained separately from the 23-hour day.
  revised := jsonb_set(jsonb_set(data,'{0,window_start}','"2026-03-08T00:00:00Z"'),'{0,window_end}','"2026-03-09T00:00:00Z"');
  if public.save_wearable_daily_totals(owner, revised) <> 1 then raise exception 'Calendar windows mixed'; end if;

  revised := jsonb_set(jsonb_set(data,'{0,metric}','"sleep"'),'{0,value}','25200');
  if public.save_wearable_daily_totals(owner, revised) <> 1 then raise exception 'Sleep import failed'; end if;
  if not exists (select from public.wearable_daily_totals where metric = 'sleep' and value = 25200)
    then raise exception 'Sleep duration unavailable'; end if;

  begin
    perform public.save_wearable_daily_totals('a1400000-0000-0000-0000-000000000002', data);
    raise exception 'Cross-account import accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.save_wearable_daily_totals(owner, jsonb_set(revised,'{0,value}','0'));
    raise exception 'Unknown sleep accepted as zero';
  exception when check_violation then null;
  end;
  begin
    perform public.save_wearable_daily_totals(owner, jsonb_set(data,'{0,window_end}','"2026-03-09T18:00:00Z"'));
    raise exception 'Impossible day window accepted';
  exception when check_violation then null;
  end;
end
$$;

select set_config('request.jwt.claim.sub', 'a1400000-0000-0000-0000-000000000002', true);
do $$
begin
  if exists (select from public.wearable_daily_totals) then raise exception 'Cross-account read'; end if;
  update public.wearable_daily_totals set value = 0;
  if found then raise exception 'Cross-account update'; end if;
  delete from public.wearable_daily_totals;
  if found then raise exception 'Cross-account delete'; end if;
end
$$;
set local role anon;
do $$
begin
  begin
    perform public.save_wearable_daily_totals(auth.uid(), '[]');
    raise exception 'Anonymous import accepted';
  exception when insufficient_privilege then null;
  end;
end
$$;
rollback;
