-- Preserve older rows. New reviewed rows use the printed text as their source of truth.
begin;

alter table public.lab_results
  alter column reported_on drop not null,
  add column reference_text text,
  add column reported_flag text,
  add column extracted_value_text text,
  add constraint nova_reviewed_lab_result check (
    source <> 'scan_reviewed' or (
      value_text is not null and char_length(btrim(value_text)) between 1 and 160
      and btrim(value_text) !~ '^[<>=≤≥[:space:]]+$'
      and value_text !~ '[[:cntrl:]]'
      and flag in ('unknown', 'low', 'high')
      and case
        when char_length(value_text) <= 32 and value_text ~ '^[+-]?([0-9]+([.][0-9]+)?|[.][0-9]+)$'
          then value is not distinct from value_text::numeric
        else value is null
      end
    )
  );

comment on column public.lab_results.value_text is 'Reviewed result as printed. Use value only as a projection of an exact decimal.';
comment on column public.lab_results.reported_on is 'Date printed on the report, or NULL if unknown.';

commit;
