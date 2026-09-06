-- Проверка уровня относится к АКТИВНОЙ паре, а не к любой попавшейся.
--
-- ЧТО ПРОИСХОДИЛО. Игрок с несколькими парами не мог пройти дальше выбора
-- уровня: и «Начать игру», и сама проверка отвечали placement_already_done,
-- и обойти это было нечем — экран просто не пускал дальше.
--
-- Складывалось из двух половин, каждая из которых по отдельности выглядела
-- безобидно:
--
-- 1. Маршрутизация на старте (resolveStartDestination) брала ЛЮБУЮ строку
--    learning — `limit 1` без порядка и без фильтра по активности — и по
--    её placement_done решала, вести ли на экран уровня. Пары, добавленные
--    через add_language_pair, приходят с placement_done = false: определения
--    уровня для второй и следующих пар нет, его проходят только при
--    регистрации. Стоило завести вторую пару — и жребий мог выпасть на неё.
--
-- 2. Экраны при этом работают с АКТИВНОЙ парой (level_select читает
--    is_active = true). У активной пары уровень давно определён, значит
--    update находил 0 строк и функция честно отвечала «уже пройдено».
--
-- То есть маршрут вёл на экран из-за одной пары, а экран действовал на
-- другую. Ни одна из половин не была неправа в одиночку.
--
-- ВТОРАЯ ПРИЧИНА, вскрывшаяся тем же местом: после 0034 у игрока могут
-- быть ДВЕ пары с одним изучаемым языком (ru-es и en-es). Все запросы
-- здесь адресуют пару по одному language_code с `limit 1` — то есть
-- выбирают из двух наугад. Пока пар с общим изучаемым не было, это не
-- проявлялось; теперь проявится.
--
-- Адресуем активную: проверка уровня всегда относится к паре, которой
-- сейчас играют. `order by is_active desc, native_for` вместо голого
-- `limit 1` делает выбор определённым и при этом не меняет сигнатуры
-- функций — а значит не плодит перегрузок (см. 0035 о том, чем это
-- кончается).

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
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_rating := public.rating_for_cefr_level(p_level);
  if v_rating is null then
    raise exception 'unknown_cefr_level: %', p_level;
  end if;

  -- Сначала активная пара, и только потом любая другая с этим изучаемым
  -- языком. Тай-брейк по native_for — не потому, что один родной язык
  -- чем-то лучше другого, а потому, что порядок обязан быть
  -- предсказуемым: без него выбор зависел бы от того, как лягут строки на
  -- диске. Времени создания у строк нет, а id — случайный uuid, сортировка
  -- по нему была бы жребием с видом порядка.
  select id into v_id
    from user_languages
   where user_id = v_uid
     and role = 'learning'
     and language_code = p_target_language
     and placement_done = false
   order by is_active desc, native_for
   limit 1;

  if v_id is null then
    -- Либо пары нет, либо уровень на ней уже определён. Разделять эти два
    -- случая для клиента незачем: оба означают «этот вызов недействителен».
    raise exception 'placement_already_done';
  end if;

  update user_languages
     set rating = v_rating,
         placement_done = true,
         rating_updated_at = now()
   where id = v_id;

  return jsonb_build_object('rating', v_rating, 'level', lower(p_level));
end;
$$;

grant execute on function public.set_placement_rating(text, text) to authenticated;

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
    -- Проверка уровня по-прежнему бесплатна целиком: провалить её и
    -- захотеть пройти заново — нормальный сценарий онбординга, и упереться
    -- в пустой запас там значило бы застрять, не начав играть.
    --
    -- Ищем НЕПРОЙДЕННУЮ пару с этим языком, предпочитая активную. Прежний
    -- запрос брал любую строку и спрашивал её placement_done: наткнувшись
    -- на уже пройденную пару, он отказывал, хотя рядом лежала та, ради
    -- которой игрок сюда и пришёл.
    select true into v_placement_open
      from user_languages
     where user_id = v_uid
       and role = 'learning'
       and language_code = p_target_language
       and placement_done = false
     order by is_active desc, native_for
     limit 1;
    if coalesce(v_placement_open, false) = false then
      raise exception 'placement_already_done';
    end if;
  else
    v_wallet := public.regen_energy(v_uid);
    if v_wallet.energy_current < 1 then
      raise exception 'no_energy';
    end if;
  end if;

  select league_rating into v_league_rating
    from user_languages
   where user_id = v_uid
     and role = 'learning'
     and language_code = p_target_language
   order by is_active desc, native_for
   limit 1;

  insert into training_sessions (user_id, target_language, reference_elo, is_placement)
    values (v_uid, p_target_language, coalesce(v_league_rating, 1000), p_is_placement)
    returning id into v_session_id;

  return jsonb_build_object('session_id', v_session_id, 'reference_elo', coalesce(v_league_rating, 1000));
end;
$$;

grant execute on function public.start_training_session(text, boolean) to authenticated;
