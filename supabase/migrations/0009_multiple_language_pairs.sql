-- Chrolingo — несколько языковых пар на аккаунт (до 4), с отдельным ELO
-- на каждую и переключением активной пары без сброса рейтинга.
--
-- Родной язык (users.native_language) остаётся ОДНИМ фиксированным
-- свойством аккаунта — эта задача не про смену родного языка, только про
-- несколько ИЗУЧАЕМЫХ (role='learning') языков одновременно. У каждого
-- изучаемого языка — своя строка в user_languages (это уже позволяла
-- исходная схема, unique был по (user_id, language_code, role), просто
-- весь остальной код везде брал "любую" learning-строку как единственную).
-- Теперь ровно одна из них помечена is_active — её и берёт весь код.

alter table user_languages add column if not exists is_active boolean not null default false;

-- Бэкофилл: на момент этой миграции у каждого аккаунта ровно одна
-- learning-строка (так гарантировал онбординг) — делаем её активной.
update user_languages set is_active = true where role = 'learning';

-- Гарантия на уровне БД: не больше одной активной learning-пары на
-- аккаунт, даже если в RPC ниже когда-нибудь закрадётся баг.
create unique index if not exists user_languages_one_active_learning
  on user_languages (user_id)
  where role = 'learning' and is_active = true;

-- =========================================================================
-- add_language_pair — добавляет НОВЫЙ изучаемый язык (до 4 штук на
-- аккаунт), НЕ трогая текущую активную пару и её ELO.
-- =========================================================================

create or replace function public.add_language_pair(p_target_language text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_native text;
  v_count integer;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select native_language into v_native from users where id = v_uid;
  if v_native is null then
    raise exception 'native language is not set yet';
  end if;
  if p_target_language = v_native then
    raise exception 'target_equals_native';
  end if;

  if exists (
    select 1 from user_languages
    where user_id = v_uid and role = 'learning' and language_code = p_target_language
  ) then
    raise exception 'pair_already_exists';
  end if;

  select count(*) into v_count from user_languages where user_id = v_uid and role = 'learning';
  if v_count >= 4 then
    raise exception 'pair_limit_reached';
  end if;

  insert into user_languages (user_id, language_code, role, cefr_level, elo, league, is_active)
    values (v_uid, p_target_language, 'learning', 'A1', 1000, 'bronze', false)
    returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.add_language_pair(text) to authenticated;

-- =========================================================================
-- set_active_language_pair — переключает, какая из уже добавленных пар
-- активна везде в приложении (Арена, бой, матчмейкинг, Тренировка).
-- Рейтинг НИ У ОДНОЙ пары не меняется — просто читается/пишется другая
-- строка.
-- =========================================================================

create or replace function public.set_active_language_pair(p_target_language text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  if not exists (
    select 1 from user_languages
    where user_id = v_uid and role = 'learning' and language_code = p_target_language
  ) then
    raise exception 'pair_not_found';
  end if;

  update user_languages set is_active = false where user_id = v_uid and role = 'learning';
  update user_languages set is_active = true
    where user_id = v_uid and role = 'learning' and language_code = p_target_language;
end;
$$;

grant execute on function public.set_active_language_pair(text) to authenticated;

grant select, insert, update, delete on all tables in schema public to authenticated;
