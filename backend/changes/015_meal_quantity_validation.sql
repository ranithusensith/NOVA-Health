begin;

-- Check future writes while preserving legacy records as entered.
alter table public.meal_logs
  add constraint nova_meal_calories check (calories between 0 and 5000) not valid,
  add constraint nova_meal_nutrients check (
    case
      when nutrients is null then true
      when jsonb_typeof(nutrients) <> 'object' then false
      when nutrients - array['protein_g', 'carbs_g', 'fat_g'] <> '{}'::jsonb then false
      when jsonb_path_exists(nutrients, 'strict $.* ? (@.type() != "number" && @.type() != "null")') then false
      else
        coalesce((nutrients->>'protein_g')::numeric between 0 and 500
          and (nutrients->>'protein_g')::numeric = trunc((nutrients->>'protein_g')::numeric, 1), true)
        and coalesce((nutrients->>'carbs_g')::numeric between 0 and 800
          and (nutrients->>'carbs_g')::numeric = trunc((nutrients->>'carbs_g')::numeric, 1), true)
        and coalesce((nutrients->>'fat_g')::numeric between 0 and 500
          and (nutrients->>'fat_g')::numeric = trunc((nutrients->>'fat_g')::numeric, 1), true)
    end
  ) not valid;

commit;
