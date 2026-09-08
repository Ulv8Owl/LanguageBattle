-- Языковая пара — просто два языка. Никакого реестра родных и никакого лимита.
--
-- ЧТО БЫЛО. Пара заводилась только «от» языка, заранее записанного в
-- user_native_languages, и добавление упиралось то в этот реестр
-- (native_not_registered), то в потолок в четыре пары. Реестр был третьим
-- местом, где хранился по сути один и тот же факт — «на каком языке игрок
-- говорит», — и он же был единственной причиной, по которой часть пар
-- завести не удавалось.
--
-- ЧТО СТАЛО. Строка user_languages с role = 'learning' И ЕСТЬ пара:
--   native_for     — язык, с которого игрок переводит (язык носителя);
--   language_code  — язык, который он изучает.
-- Больше ничего для пары не нужно. Уникальность пары держит индекс
-- user_languages_pair_key (миграция 0034), запрет один: язык нельзя учить
-- у самого себя.
--
-- Таблица user_native_languages НЕ УДАЛЯЕТСЯ и её RPC остаются рабочими:
-- сносить данные ради того, что приложение просто перестало читать, — риск
-- без выгоды. Экран «Родные языки» из настроек убран, новые записи туда
-- никто не пишет.
create or replace function public.add_language_pair(
  p_target_language text,
  p_native_language text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_native text;
  v_id uuid;
  v_hidden uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  -- Язык носителя приходит от клиента. Откат на users.native_language
  -- остался только для совсем старых вызовов без второго аргумента: сам
  -- профильный язык больше ничего не решает.
  v_native := coalesce(p_native_language, (select native_language from users where id = v_uid));
  if v_native is null or length(trim(v_native)) = 0 then
    raise exception 'native language is not set yet';
  end if;
  if p_target_language is null or length(trim(p_target_language)) = 0 then
    raise exception 'target language is not set';
  end if;
  if p_target_language = v_native then
    raise exception 'target_equals_native';
  end if;

  -- Скрытая такая же пара — не повод отказывать и уж точно не повод
  -- заводить вторую строку: у скрытой остались рейтинг и история, и
  -- вернуть их правильнее, чем начать с нуля рядом.
  select id into v_hidden
    from user_languages
   where user_id = v_uid and role = 'learning'
     and language_code = p_target_language and native_for = v_native
     and hidden_at is not null;
  if v_hidden is not null then
    update user_languages set hidden_at = null where id = v_hidden;
    return v_hidden;
  end if;

  if exists (
    select 1 from user_languages
    where user_id = v_uid and role = 'learning'
      and language_code = p_target_language and native_for = v_native
  ) then
    raise exception 'pair_already_exists';
  end if;

  insert into user_languages (user_id, language_code, role, native_for, is_active)
    values (v_uid, p_target_language, 'learning', v_native, false)
    returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.add_language_pair(text, text) to authenticated;

-- Смена ОБОИХ языков существующей пары.
--
-- Нужна проверке уровня: игрок, ошибившийся с парой при регистрации, до
-- сих пор не мог её исправить — на том экране ещё нет ни профиля, ни
-- списка пар, а заводить рядом вторую пару значило бы оставить ему
-- ненужную первую навсегда.
--
-- Меняется именно строка, а не «удалить и создать»: у пары есть рейтинг,
-- лига и уровень, и все они относятся к изучаемому языку — при смене языка
-- их надо сбросить, что здесь и делается явно.
create or replace function public.retarget_language_pair(
  p_old_target text,
  p_old_native text,
  p_new_target text,
  p_new_native text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if p_new_target = p_new_native then
    raise exception 'target_equals_native';
  end if;

  select id into v_id
    from user_languages
   where user_id = v_uid and role = 'learning'
     and language_code = p_old_target and native_for = p_old_native;
  if v_id is null then
    raise exception 'pair not found';
  end if;

  -- Такая пара у игрока уже есть — молча слить их в одну нельзя: у второй
  -- свой рейтинг и своя история. Просто делаем её активной.
  if exists (
    select 1 from user_languages
    where user_id = v_uid and role = 'learning' and id <> v_id
      and language_code = p_new_target and native_for = p_new_native
  ) then
    raise exception 'pair_already_exists';
  end if;

  update user_languages
     set language_code = p_new_target,
         native_for = p_new_native,
         -- Рейтинг и уровень относились к прежнему изучаемому языку: пара
         -- стала другой, и переносить их на неё было бы враньём про
         -- подтверждённый уровень.
         rating = public.elo_default_rating(),
         cefr_level = null,
         hidden_at = null
   where id = v_id;
end;
$$;

grant execute on function public.retarget_language_pair(text, text, text, text) to authenticated;
