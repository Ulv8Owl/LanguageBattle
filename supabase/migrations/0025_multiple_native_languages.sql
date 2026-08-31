-- Несколько родных языков на аккаунт (до 6) — для полиглотов.
--
-- users.native_language был И ОСТАЁТСЯ единственным «главным» родным
-- языком: matchmaking, ASR, onboarding, ASR-проверка «не тот язык» — всё
-- это читает именно его, и трогать эти места незачем, если игрок знает
-- только один язык (подавляющее большинство). Новая таблица —
-- НАДСТРОЙКА: список ВСЕХ родных языков, из которого users.native_language
-- всегда равен ровно одному, помеченному is_primary. Это сделано
-- умышленно, а не как временное упрощение: любой код, который сегодня
-- читает users.native_language, продолжит получать правильный ответ и
-- после того, как игрок добавит второй-третий родной язык, — потому что
-- primary синхронизируется этой же миграцией и RPC ниже, а не отдельным
-- усилием в каждом потребителе.
--
-- Второе изменение — user_languages.native_for: с КАКОГО родного языка
-- изучается конкретная пара. Полиглот с русским и китайским как родными
-- может учить английский «от русского» и японский «от китайского» —
-- разные пары, разные родные, при этом рейтинг и лига по-прежнему одни на
-- language_code (unique(user_id, language_code, role) НЕ меняется: два
-- отдельных трека для одного и того же изучаемого языка из задачи не
-- следовали — только группировка уже существующих разных пар по тому,
-- какой родной язык каждую из них анкорит).

-- -------------------------------------------------------------------------
-- Таблица родных языков
-- -------------------------------------------------------------------------

create table if not exists public.user_native_languages (
  user_id uuid not null references users(id) on delete cascade,
  language_code text not null,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (user_id, language_code)
);

comment on table public.user_native_languages is
  'Все родные языки игрока (до 6, лимит в RPC). users.native_language '
  'всегда равен тому, что здесь помечен is_primary — эту связь держат '
  'add/remove/set_primary_native_language ниже, а не триггер: так проще '
  'проверить на стенде и нет риска рекурсии между таблицами.';

-- Не больше одного is_primary=true на пользователя — гарантия на уровне
-- БД, даже если в RPC ниже когда-нибудь закрадётся баг.
create unique index if not exists user_native_languages_one_primary
  on public.user_native_languages (user_id)
  where is_primary;

alter table public.user_native_languages enable row level security;

drop policy if exists "user_native_languages: owner can view" on public.user_native_languages;
create policy "user_native_languages: owner can view"
  on public.user_native_languages for select
  to authenticated
  using (user_id = auth.uid());

-- Мутации — только через SECURITY DEFINER RPC ниже (валидация лимита в 6,
-- «должен остаться хотя бы один», переезд primary при удалении текущего).
-- Прямой insert/update/delete с клиента не разрешаем.

-- Бэкофилл: у каждого существующего пользователя ровно один родной язык —
-- он и есть primary.
insert into public.user_native_languages (user_id, language_code, is_primary)
select id, native_language, true
from public.users
where native_language is not null
on conflict (user_id, language_code) do nothing;

-- -------------------------------------------------------------------------
-- native_for — с какого родного языка изучается эта пара
-- -------------------------------------------------------------------------

alter table public.user_languages add column if not exists native_for text;

comment on column public.user_languages.native_for is
  'Родной язык, С КОТОРОГО изучается эта пара (role=learning). Определяет, '
  'на каком языке показывается задание, и уходит в ASR альтернативой для '
  'проверки «не тот язык» — раздельно для КАЖДОЙ пары, а не одно значение '
  'на весь аккаунт, потому что у полиглота пары могут быть anchored на '
  'разные родные. NULL у role=native (там этому полю нечего означать) и у '
  'пар, заведённых до этой миграции без осмысленного значения — для них '
  'бэкофилл ставит их единственный на тот момент родной язык.';

update public.user_languages ul
set native_for = u.native_language
from public.users u
where ul.user_id = u.id
  and ul.role = 'learning'
  and ul.native_for is null;

-- -------------------------------------------------------------------------
-- Онбординг и старый одиночный picker в Настройках пишут users.native_
-- language НАПРЯМУЮ (update, не RPC) — и должны иметь право продолжать
-- так делать, не зная о существовании user_native_languages вообще.
-- Триггер — единственное место, которое обязано держать эту связь: если
-- полагаться на то, что каждый будущий код, пишущий users.native_language,
-- не забудет продублировать запись сюда, рано или поздно кто-то забудет.
-- -------------------------------------------------------------------------

create or replace function public.sync_primary_native_language()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.native_language is null then
    return new;
  end if;

  insert into user_native_languages (user_id, language_code, is_primary)
    values (new.id, new.native_language, true)
  on conflict (user_id, language_code) do nothing;

  -- Строка могла уже существовать (игрок раньше уже называл этот язык
  -- родным, потом переключился и вернулся) — тогда insert выше ничего не
  -- сделал, а primary всё равно нужно передвинуть именно на него.
  update user_native_languages set is_primary = false
    where user_id = new.id and is_primary and language_code <> new.native_language;
  update user_native_languages set is_primary = true
    where user_id = new.id and language_code = new.native_language;

  return new;
end;
$$;

drop trigger if exists trg_sync_primary_native_language on users;
create trigger trg_sync_primary_native_language
  after insert or update of native_language on users
  for each row execute function public.sync_primary_native_language();

-- -------------------------------------------------------------------------
-- add_native_language / remove_native_language / set_primary_native_language
-- -------------------------------------------------------------------------

create or replace function public.add_native_language(p_language_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if p_language_code is null or length(trim(p_language_code)) = 0 then
    raise exception 'invalid language code';
  end if;

  if exists (
    select 1 from user_native_languages where user_id = v_uid and language_code = p_language_code
  ) then
    raise exception 'already_native';
  end if;

  select count(*) into v_count from user_native_languages where user_id = v_uid;
  if v_count >= 6 then
    raise exception 'native_limit_reached';
  end if;

  -- Первый родной язык вообще (не должно случаться — бэкофилл и онбординг
  -- всегда заводят один, но не полагаемся на это молча) сразу primary.
  insert into user_native_languages (user_id, language_code, is_primary)
    values (v_uid, p_language_code, v_count = 0);

  if v_count = 0 then
    update users set native_language = p_language_code where id = v_uid;
  end if;
end;
$$;

grant execute on function public.add_native_language(text) to authenticated;

create or replace function public.remove_native_language(p_language_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_was_primary boolean;
  v_count integer;
  v_next_primary text;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select is_primary into v_was_primary
    from user_native_languages where user_id = v_uid and language_code = p_language_code;
  if v_was_primary is null then
    raise exception 'not_native';
  end if;

  select count(*) into v_count from user_native_languages where user_id = v_uid;
  if v_count <= 1 then
    raise exception 'must_keep_one_native';
  end if;

  delete from user_native_languages where user_id = v_uid and language_code = p_language_code;

  -- Удалили ГЛАВНЫЙ родной язык — назначаем следующим по времени
  -- добавления. Без этого users.native_language указывал бы на язык,
  -- которого у игрока по факту уже нет в списке.
  if v_was_primary then
    select language_code into v_next_primary
      from user_native_languages where user_id = v_uid order by created_at limit 1;
    update user_native_languages set is_primary = true
      where user_id = v_uid and language_code = v_next_primary;
    update users set native_language = v_next_primary where id = v_uid;
  end if;
end;
$$;

grant execute on function public.remove_native_language(text) to authenticated;

create or replace function public.set_primary_native_language(p_language_code text)
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
    select 1 from user_native_languages where user_id = v_uid and language_code = p_language_code
  ) then
    raise exception 'not_native';
  end if;

  update user_native_languages set is_primary = false where user_id = v_uid and is_primary;
  update user_native_languages set is_primary = true
    where user_id = v_uid and language_code = p_language_code;
  update users set native_language = p_language_code where id = v_uid;
end;
$$;

grant execute on function public.set_primary_native_language(text) to authenticated;

-- -------------------------------------------------------------------------
-- add_language_pair — теперь может анкорить пару на ЛЮБОЙ из
-- зарегистрированных родных языков, не только на главный.
-- -------------------------------------------------------------------------

-- Старая версия (2009) принимала один аргумент. Postgres различает функции
-- по СИГНАТУРЕ, а не по имени: create or replace с другим числом
-- параметров создал бы ВТОРУЮ перегруженную функцию рядом со старой, а не
-- заменил её — и вызов с одним p_target_language стал бы неоднозначным
-- между старой (1 параметр) и новой (2-й со значением по умолчанию).
-- Явный drop убирает старую сигнатуру, оставляя ровно одну функцию.
drop function if exists public.add_language_pair(text);

create or replace function public.add_language_pair(p_target_language text, p_native_language text default null)
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

  -- Без явного родного — прежнее поведение (главный родной язык). Явный
  -- родной обязан быть уже зарегистрирован через add_native_language:
  -- иначе игрок мог бы завести пару «от языка», который сам не назвал
  -- своим, и это разошлось бы со списком в Настройках.
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

  -- elo/league/cefr_level НЕ перечислены: их ставит trg_sync_rating_mirrors
  -- по умолчаниям rating/rating_deviation (миграция 0023) — задавать их
  -- здесь значило бы писать числа, которые тот же insert тут же перезапишет.
  insert into user_languages (user_id, language_code, role, native_for, is_active)
    values (v_uid, p_target_language, 'learning', v_native, false)
    returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.add_language_pair(text, text) to authenticated;
