-- Языковая пара — это РОДНОЙ ПЛЮС ИЗУЧАЕМЫЙ, а не один изучаемый.
--
-- ЧТО БЫЛО СЛОМАНО. Три вещи, и все три растут из одного допущения: будто
-- пару достаточно назвать изучаемым языком.
--
-- 1. Пара переанкоривалась при смене главного родного. user_languages.
--    native_for (родной ИМЕННО этой пары) появился в 0025, но строки,
--    создаваемые при регистрации, его не заполняли. У первой пары каждого
--    аккаунта там оставался null, а весь клиент читает
--    `native_for ?? users.native_language`. Пока главный родной не меняли,
--    подмены не было видно. Стоило сменить русский на английский — и пара
--    ru-en превращалась в en-en: язык сам себе родной.
--
-- 2. Нельзя было завести вторую пару с тем же изучаемым языком. unique
--    (user_id, language_code, role) из 0001 не различает ru-es и en-es:
--    для него это одна строка. Игрок с двумя родными не мог учить
--    испанский и от русского, и от английского — а именно за этим
--    заводят второй родной.
--
-- 3. add_language_pair и set_active_language_pair искали пару по одному
--    p_target_language. С двумя парами на один изучаемый язык первая
--    отказывала как «уже есть», вторая переключала неизвестно какую.
--
-- ГЛАВНОЕ ПРАВИЛО, которое эта миграция закрепляет: заведённая пара НЕ
-- МЕНЯЕТСЯ. Что бы игрок ни делал со списком родных языков — добавлял,
-- менял главный, удалял, — существующие пары остаются как есть. Родной
-- язык пары фиксируется в момент её создания и с тех пор живёт своей
-- жизнью.

-- -------------------------------------------------------------------------
-- 1. Дозаполнить native_for и запретить null у изучаемых пар
-- -------------------------------------------------------------------------

-- Лучшая доступная догадка для строк, оставшихся с null: главный родной
-- игрока. Она не идеальна — если игрок УЖЕ сменил главный родной, пара
-- зафиксируется на новом языке, а не на том, с которого он начинал. Но
-- альтернатив нет: прежнее значение нигде не сохранялось, и оставить null
-- значило бы оставить ту самую подмену на будущее.
update user_languages ul
set native_for = u.native_language
from users u
where ul.user_id = u.id
  and ul.role = 'learning'
  and ul.native_for is null
  and u.native_language is not null;

-- Пара, у которой не записан родной язык, — это пара, которая завтра
-- станет чужой. Запрет на null дешевле любой починки постфактум.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'user_languages_learning_has_native'
  ) then
    alter table user_languages
      add constraint user_languages_learning_has_native
      check (role <> 'learning' or native_for is not null) not valid;
  end if;
end $$;

-- not valid + validate: старые строки, которые почему-то не поддались
-- дозаполнению (у игрока не задан native_language вовсе), не должны
-- ронять всю миграцию. Если такие есть, валидация упадёт здесь, и это
-- правильное место, чтобы об этом узнать.
alter table user_languages validate constraint user_languages_learning_has_native;

-- -------------------------------------------------------------------------
-- 2. Ключ пары: родной + изучаемый
-- -------------------------------------------------------------------------

-- Имя ограничения из 0001 сгенерировано Postgres по столбцам.
alter table user_languages
  drop constraint if exists user_languages_user_id_language_code_role_key;

-- coalesce, а не сам native_for: у родных строк (role = 'native') он null,
-- а null в unique-индексе не равен другому null — то есть один и тот же
-- родной язык можно было бы записать дважды. Пустая строка так себя не
-- ведёт и держит прежнюю защиту для родных строк.
create unique index if not exists user_languages_pair_key
  on user_languages (user_id, role, language_code, coalesce(native_for, ''));

-- -------------------------------------------------------------------------
-- 3. Скрытие плашки — НЕ удаление пары
-- -------------------------------------------------------------------------

-- Игрок просит убрать плашку с профиля, а не стереть рейтинг, лигу и
-- историю по этой паре. Это разные желания, и второе необратимо: удалив
-- строку, мы потеряли бы месяцы прогресса ради наведения порядка на
-- экране. Поэтому скрытие — отметка времени, а сама пара остаётся целой и
-- возвращается на место, если игрок заведёт её снова.
alter table user_languages
  add column if not exists hidden_at timestamptz;

comment on column user_languages.hidden_at is
  'Плашка пары убрана с профиля. Сама пара цела: рейтинг, лига и история '
  'остаются, повторное добавление той же пары просто снимает отметку. '
  'Активную пару скрыть нельзя — сначала выберите другую.';

-- -------------------------------------------------------------------------
-- 4. RPC: адресуем пару целиком
-- -------------------------------------------------------------------------

-- Обе функции получают второй аргумент со значением по умолчанию, но
-- перегрузку это создать не может: у старых сигнатур то же число
-- параметров или они сняты явным drop (см. 0025 про то, чем это грозит).

create or replace function public.set_active_language_pair(
  p_target_language text,
  p_native_language text default null
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

  -- Без явного родного берём любую пару с этим изучаемым языком —
  -- прежнее поведение для клиентов, которые ещё не знают про второй
  -- аргумент. С явным родным адресуем ровно одну.
  select id into v_id
    from user_languages
   where user_id = v_uid
     and role = 'learning'
     and language_code = p_target_language
     and (p_native_language is null or native_for = p_native_language)
   order by hidden_at nulls first
   limit 1;

  if v_id is null then
    raise exception 'pair_not_found';
  end if;

  update user_languages set is_active = false where user_id = v_uid and role = 'learning';
  -- Выбор активной снимает скрытие: пара, по которой играют, обязана быть
  -- видна на профиле, иначе игрок не поймёт, откуда взялись эти фразы.
  update user_languages set is_active = true, hidden_at = null where id = v_id;
end;
$$;

grant execute on function public.set_active_language_pair(text, text) to authenticated;

-- Плашку убрать, пару сохранить.
create or replace function public.hide_language_pair(
  p_target_language text,
  p_native_language text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_active boolean;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select id, is_active into v_id, v_active
    from user_languages
   where user_id = v_uid
     and role = 'learning'
     and language_code = p_target_language
     and (p_native_language is null or native_for = p_native_language)
     and hidden_at is null
   limit 1;

  if v_id is null then
    raise exception 'pair_not_found';
  end if;

  -- Скрыть активную пару нельзя: ровно одна пара обязана быть активной
  -- (unique-индекс из 0009), и без неё Арена, бой и Тренировка не знают,
  -- на каком языке работать. Отказ здесь понятнее, чем игра, которая
  -- перестала запускаться после наведения порядка на профиле.
  if v_active then
    raise exception 'cannot_hide_active_pair';
  end if;

  update user_languages set hidden_at = now() where id = v_id;
end;
$$;

grant execute on function public.hide_language_pair(text, text) to authenticated;

-- add_language_pair: пара уникальна по родному И изучаемому, а
-- повторное добавление скрытой пары возвращает её на профиль.
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
  v_count integer;
  v_id uuid;
  v_hidden uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select native_language into v_native from users where id = v_uid;
  if v_native is null then
    raise exception 'native language is not set yet';
  end if;

  if p_native_language is not null then
    if not exists (
      select 1 from user_native_languages where user_id = v_uid and language_code = p_native_language
    ) then
      raise exception 'native_not_registered';
    end if;
    v_native := p_native_language;
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

  -- Дубликат теперь считается по паре целиком. Прежняя проверка смотрела
  -- на один изучаемый язык и запрещала ru-es рядом с en-es.
  if exists (
    select 1 from user_languages
    where user_id = v_uid and role = 'learning'
      and language_code = p_target_language and native_for = v_native
  ) then
    raise exception 'pair_already_exists';
  end if;

  -- Лимит считает ВИДИМЫЕ пары: скрытая плашки не занимает, и держать
  -- игрока на голодном пайке из-за пары, которой он не видит, незачем.
  select count(*) into v_count
    from user_languages
   where user_id = v_uid and role = 'learning' and hidden_at is null;
  if v_count >= 4 then
    raise exception 'pair_limit_reached';
  end if;

  insert into user_languages (user_id, language_code, role, native_for, is_active)
    values (v_uid, p_target_language, 'learning', v_native, false)
    returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.add_language_pair(text, text) to authenticated;
