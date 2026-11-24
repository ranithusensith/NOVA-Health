-- One PostgREST transaction for the signed-in patient's profile form.
begin;

create or replace function public.save_health_profile(
  p_expected_user_id uuid,
  p_full_name text,
  p_birth_date date,
  p_sex text,
  p_blood_type text,
  p_height_cm numeric,
  p_weight_kg numeric,
  p_conditions text[],
  p_medical_notes text,
  p_allergies text[]
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  account_id uuid := auth.uid();
  full_name_input text := regexp_replace(p_full_name, '^[[:space:]]+|[[:space:]]+$', '', 'g');
  wanted_allergies text[];
begin
  if account_id is null or account_id is distinct from p_expected_user_id then
    raise insufficient_privilege using message = 'Sign in again to save your health profile.';
  end if;

  if full_name_input is null or char_length(full_name_input) < 2
     or p_birth_date is null or p_birth_date not between date '1900-01-01' and current_date
     or p_sex is null or p_sex not in ('female', 'male', 'other', 'prefer_not_to_say')
     or (p_blood_type is not null and p_blood_type not in ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-', 'unknown'))
     or p_height_cm is null or p_height_cm not between 50 and 250
     or p_weight_kg is null or p_weight_kg not between 2 and 400
     or p_conditions is null or array_position(p_conditions, null) is not null
     or p_allergies is null or array_position(p_allergies, null) is not null then
    raise invalid_parameter_value using message = 'Check your health profile details and try again.';
  end if;

  select coalesce(array_agg(name), '{}'::text[]) into wanted_allergies
  from (
    select distinct on (lower(name)) name
    from (
      select regexp_replace(value, '^[[:space:]]+|[[:space:]]+$', '', 'g') as name, position
      from unnest(p_allergies) with ordinality as entry(value, position)
    ) trimmed
    where name <> ''
    order by lower(name), position desc
  ) normalized;

  -- Serialize saves for this profile before editing its allergy list.
  perform 1 from public.profiles where id = account_id for no key update;
  if not found then
    raise insufficient_privilege using message = 'Profile unavailable. Sign in again and retry.';
  end if;

  -- Keep IDs, source and other metadata for confirmed allergies already on the form.
  delete from public.allergies existing
  where existing.user_id = account_id and existing.status = 'confirmed'
    and not exists (
      select from unnest(wanted_allergies) as wanted(name)
      where lower(wanted.name) = lower(existing.name)
    );

  insert into public.allergies (user_id, name, source, status)
  select account_id, wanted.name, 'user', 'confirmed'
  from unnest(wanted_allergies) as wanted(name)
  where not exists (
    select from public.allergies existing
    where existing.user_id = account_id and existing.status = 'confirmed'
      and lower(existing.name) = lower(wanted.name)
  );

  -- A legacy DELETE policy or trigger can silently skip a visible row.
  if exists (
    select lower(name) from public.allergies
    where user_id = account_id and status = 'confirmed'
    except
    select lower(name) from unnest(wanted_allergies) as wanted(name)
  ) or exists (
    select lower(name) from unnest(wanted_allergies) as wanted(name)
    except
    select lower(name) from public.allergies
    where user_id = account_id and status = 'confirmed'
  ) then
    raise insufficient_privilege using message = 'Could not save the complete allergy list.';
  end if;

  update public.profiles
  set full_name = full_name_input,
      birth_date = p_birth_date,
      sex = p_sex,
      blood_type = p_blood_type,
      height_cm = p_height_cm,
      weight_kg = p_weight_kg,
      conditions = p_conditions,
      medical_notes = nullif(btrim(p_medical_notes), ''),
      onboarding_done = true
  where id = account_id;
  if not found then
    raise insufficient_privilege using message = 'Could not save your health profile.';
  end if;
end
$$;

revoke all on function public.save_health_profile(uuid, text, date, text, text, numeric, numeric, text[], text, text[])
  from public, anon;
grant execute on function public.save_health_profile(uuid, text, date, text, text, numeric, numeric, text[], text, text[])
  to authenticated;

commit;
