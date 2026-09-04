-- =========================================================================
-- Определение уровня при регистрации (placement).
--
-- Раньше новый игрок начинал с рейтинга новичка и «нащупывал» свою лигу
-- матчами. Для того, кто уже владеет языком на B2, это означало десяток
-- матчей на фразах уровня A1 — то есть первое впечатление об игре как о
-- слишком простой. Теперь после ника и языковой пары игрок сам называет
-- свой уровень по CEFR, а игра проверяет заявку одной Одиночной Игрой на
-- фразах этого уровня и только потом ставит рейтинг.
--
-- Стартовый рейтинг уровня — НАЧАЛО соответствующей лиги, а не её
-- середина: заявивший B1 должен начать ровно с порога Серебра и подниматься
-- игрой, а не получить половину лиги авансом. Исключение — A1: Олово
-- занимает целых 0..1200, и сажать «начального» игрока в самый низ рядом с
-- тем, кто языка не знает вовсе, неправильно, поэтому A1 — середина Олова.
--
--   A0  ->    0   Олово    (начинает с нуля)
--   A1  ->  600   Олово    (середина: язык уже начат)
--   A2  -> 1200   Бронза
--   B1  -> 1500   Серебро
--   B2  -> 1800   Золото
--   C1  -> 2100   Платина
--   C2  -> 2400   Алмаз
-- =========================================================================

alter table user_languages
  add column if not exists placement_done boolean not null default false;

comment on column user_languages.placement_done is
  'Прошёл ли игрок определение уровня на этой паре. false — приложение '
  'ведёт его на экран выбора уровня CEFR вместо Арены. Ставится в true '
  'ТОЛЬКО из set_placement_rating, то есть после сданной проверки.';

-- Все, кто зарегистрировался ДО появления экрана уровня, уже играли и
-- заработали свой рейтинг матчами — гнать их на определение уровня нельзя,
-- это отобрало бы у них рейтинг. Поэтому существующим строкам ставим
-- «уровень определён», и экран увидят только новые.
update user_languages set placement_done = true where placement_done = false;

/**
 * Стартовый рейтинг для уровня CEFR. Единственное место, где живёт эта
 * таблица соответствий на сервере; клиентская копия — cefrLevels в
 * lib/core/cefr_levels.dart, и тест проверяет, что они совпадают.
 *
 * Возвращает null для неизвестного кода — вызывающий обязан это отличить
 * от «уровень A0, рейтинг 0».
 */
create or replace function public.rating_for_cefr_level(p_level text)
returns integer
language sql
immutable
as $$
  select case lower(p_level)
    when 'a0' then 0
    when 'a1' then 600
    when 'a2' then 1200
    when 'b1' then 1500
    when 'b2' then 1800
    when 'c1' then 2100
    when 'c2' then 2400
    else null
  end;
$$;

/**
 * Ставит рейтинг по выбранному уровню и закрывает определение уровня.
 *
 * Вызывается ТОЛЬКО после сданной проверки (Одиночная Игра на фразах этого
 * уровня, >= 60% правильных) — саму проверку считает клиент по баллам,
 * которые выставил серверный судья, потому что баллы за раунды и так
 * лежат в training_rounds и подделать их с клиента нельзя.
 *
 * Один раз на пару: p_level приходит с клиента, и без этого ограничения
 * игрок мог бы вызывать функцию после каждого проигранного матча и
 * возвращать себе рейтинг C2. Повторный вызов — исключение, а не тихое
 * «ничего не произошло»: клиент не должен думать, что рейтинг применился.
 */
create or replace function public.set_placement_rating(
  p_target_language text,
  p_level text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_rating integer;
  v_updated integer;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_rating := public.rating_for_cefr_level(p_level);
  if v_rating is null then
    raise exception 'unknown_cefr_level: %', p_level;
  end if;

  update user_languages
    set rating = v_rating,
        placement_done = true,
        rating_updated_at = now()
    where user_id = v_uid
      and language_code = p_target_language
      and role = 'learning'
      and placement_done = false;
  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    -- Либо пары нет, либо уровень на ней уже определён. Разделять эти два
    -- случая для клиента незачем: оба означают «этот вызов недействителен».
    raise exception 'placement_already_done';
  end if;

  return jsonb_build_object('rating', v_rating, 'level', lower(p_level));
end;
$$;

/**
 * Одиночная Игра. К версии из 0023 добавлен режим проверки уровня.
 *
 * p_is_placement = true — сессия проверки при регистрации:
 *   * НЕ списывает энергию. Проверку можно провалить и захотеть пройти
 *     заново («Попробуйте ещё раз»), и упереться при этом в пустую энергию
 *     означало бы застрять в онбординге, не начав играть;
 *   * разрешена, только пока уровень на паре не определён — иначе это был
 *     бы способ играть в Одиночную Игру бесплатно и бесконечно.
 * Всё остальное (проверка подписки, создание сессии) — как в обычном режиме.
 */
create or replace function public.start_training_session(
  p_target_language text,
  p_is_placement boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_wallet currency_wallets%rowtype;
  v_league_rating integer;
  v_session_id uuid;
  v_placement_open boolean;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if not public.has_game_access(v_uid) then
    raise exception 'subscription_required';
  end if;

  if p_is_placement then
    select not placement_done into v_placement_open from user_languages
      where user_id = v_uid and language_code = p_target_language and role = 'learning'
      limit 1;
    if coalesce(v_placement_open, false) = false then
      raise exception 'placement_already_done';
    end if;
  else
    v_wallet := public.regen_energy(v_uid);
    if v_wallet.energy_current < 1 then
      raise exception 'no_energy';
    end if;
    update currency_wallets set energy_current = energy_current - 1 where user_id = v_uid;
  end if;

  select league_rating into v_league_rating from user_languages
    where user_id = v_uid and language_code = p_target_language and role = 'learning'
    limit 1;

  insert into training_sessions (user_id, target_language, reference_elo)
    values (v_uid, p_target_language, coalesce(v_league_rating, 1000))
    returning id into v_session_id;

  return jsonb_build_object('session_id', v_session_id, 'reference_elo', coalesce(v_league_rating, 1000));
end;
$$;

-- Прежняя одноаргументная версия осталась бы отдельной перегрузкой (в
-- Postgres функции с разной арностью — разные функции), и PostgREST выбирал
-- бы её на старых вызовах в обход проверки placement. Сносим явно.
drop function if exists public.start_training_session(text);

grant execute on function public.rating_for_cefr_level(text) to authenticated;
grant execute on function public.set_placement_rating(text, text) to authenticated;
grant execute on function public.start_training_session(text, boolean) to authenticated;
