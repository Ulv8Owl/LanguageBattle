-- Chrolingo — приравнивание 6 лиг к 6 уровням CEFR (A1..C2) + магазин
-- наборов слов для Тренировки (карточки), привязанный к лиге игрока.
--
-- ВАЖНО про видимость: это исключительно внутренняя механика для LLM-судьи
-- и для гейтинга контента. Никакой CEFR-надписи или названия уровня нигде
-- в интерфейсе не показывается — только внутри промптов и в логике сервера.

-- =========================================================================
-- 1. Единый источник истины для порогов лиги/уровня — те же границы ELO,
--    что и в lib/core/leagues.dart (leagueBands). Если поменяете одно,
--    обязательно поменяйте и другое — они специально продублированы
--    (Dart-клиент и Postgres не могут делить один файл), но обязаны
--    совпадать.
-- =========================================================================

create or replace function public.league_index_for_elo(p_elo integer)
returns integer
language sql
immutable
as $$
  select case
    when p_elo < 1200 then 0  -- Медная Лига
    when p_elo < 1500 then 1  -- Серебряная Лига
    when p_elo < 1800 then 2  -- Золотая Лига
    when p_elo < 2100 then 3  -- Платиновая Лига
    when p_elo < 2400 then 4  -- Алмазная Лига
    else 5                    -- Лига Мастеров
  end;
$$;

create or replace function public.league_slug_for_elo(p_elo integer)
returns text
language sql
immutable
as $$
  select (array['bronze','silver','gold','platinum','diamond','master'])[public.league_index_for_elo(p_elo) + 1];
$$;

-- Медная->A1, Серебряная->A2, Золотая->B1, Платиновая->B2, Алмазная->C1,
-- Мастеров->C2 — по прямой просьбе автора (см. чат), скрыто от игрока.
create or replace function public.cefr_level_for_elo(p_elo integer)
returns text
language sql
immutable
as $$
  select (array['A1','A2','B1','B2','C1','C2'])[public.league_index_for_elo(p_elo) + 1];
$$;

-- =========================================================================
-- 2. user_languages.league/cefr_level были в схеме с самого начала, но
--    после вставки строки их никто не обновлял (см. добавление в
--    add_language_pair, 0009) — реальный расчёт лиги всегда жил только на
--    клиенте (leagueFor(elo) в Dart). Теперь эти колонки поддерживаются
--    сервером в актуальном состоянии на каждое изменение elo — это нужно
--    и для word_pack_purchases ниже (гейтинг по лиге), и на будущее для
--    любого другого места, которому нужна лига без похода в Dart.
-- =========================================================================

create or replace function public.sync_league_columns()
returns trigger
language plpgsql
as $$
begin
  new.league := public.league_slug_for_elo(new.elo);
  new.cefr_level := public.cefr_level_for_elo(new.elo);
  return new;
end;
$$;

drop trigger if exists trg_sync_league_columns on user_languages;
create trigger trg_sync_league_columns
  before insert or update of elo on user_languages
  for each row execute function public.sync_league_columns();

-- Бэкофилл существующих строк (триггер на UPDATE OF elo срабатывает, даже
-- если значение не меняется, — этого достаточно, чтобы пересчитать league/
-- cefr_level у уже существующих аккаунтов).
update user_languages set elo = elo;

-- =========================================================================
-- 3. Банк слов Тренировки: 6 уровней (level_index 0..5 = Медная..Мастеров
--    = A1..C2) по 1000 слов, разбитых на 10 наборов по 100 (pack_index
--    0..9). Сам текст слов (ru/en/es) — статичные ассеты приложения
--    (assets/vocab/words_a1.json..c2.json), в БД живёт только ВЛАДЕНИЕ
--    набором: одна и та же покупка открывает набор сразу для всех языковых
--    пар аккаунта (это не языко-специфичный контент, а набор понятий,
--    показываемых на нужном языке).
--
--    Набор (0,0) — первые 100 слов A1 — бесплатен и доступен всем всегда,
--    без строки в word_pack_purchases (см. always-owned в list_word_packs).
-- =========================================================================

create or replace function public.word_pack_price(p_level_index integer, p_pack_index integer)
returns integer
language sql
immutable
as $$
  select (60 + p_level_index * 80) + p_pack_index * 20;
$$;

create table if not exists public.word_pack_purchases (
  user_id uuid not null references users(id) on delete cascade,
  level_index integer not null check (level_index between 0 and 5),
  pack_index integer not null check (pack_index between 0 and 9),
  purchased_at timestamptz not null default now(),
  primary key (user_id, level_index, pack_index)
);

alter table word_pack_purchases enable row level security;

drop policy if exists "word_pack_purchases: owner can view" on word_pack_purchases;
create policy "word_pack_purchases: owner can view"
  on word_pack_purchases for select
  to authenticated
  using (user_id = auth.uid());

-- purchase_word_pack: гейт по лиге (нельзя купить набор выше своей текущей
-- лиги — "с поднятием на новую лигу открывается возможность купить наборы
-- из следующей тысячи") + монеты, тем же паттерном, что purchase_item.
create or replace function public.purchase_word_pack(p_level_index integer, p_pack_index integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_elo integer;
  v_league_index integer;
  v_price integer;
  v_wallet currency_wallets%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if p_level_index < 0 or p_level_index > 5 or p_pack_index < 0 or p_pack_index > 9 then
    raise exception 'invalid pack';
  end if;
  if p_level_index = 0 and p_pack_index = 0 then
    raise exception 'pack_already_free';
  end if;

  if exists (
    select 1 from word_pack_purchases
    where user_id = v_uid and level_index = p_level_index and pack_index = p_pack_index
  ) then
    raise exception 'item already owned';
  end if;

  select elo into v_elo from user_languages
    where user_id = v_uid and role = 'learning' and is_active = true;
  v_league_index := public.league_index_for_elo(coalesce(v_elo, 1000));
  if p_level_index > v_league_index then
    raise exception 'league_locked';
  end if;

  v_price := public.word_pack_price(p_level_index, p_pack_index);

  select * into v_wallet from currency_wallets where user_id = v_uid for update;
  if not found then
    raise exception 'wallet not found for current user';
  end if;
  if v_wallet.soft_currency < v_price then
    raise exception 'insufficient_funds';
  end if;

  update currency_wallets set soft_currency = soft_currency - v_price where user_id = v_uid;
  insert into word_pack_purchases (user_id, level_index, pack_index) values (v_uid, p_level_index, p_pack_index)
    on conflict (user_id, level_index, pack_index) do nothing;
end;
$$;

grant execute on function public.purchase_word_pack(integer, integer) to authenticated;

-- Каталог наборов слов одним вызовом (цена/владение/доступность по лиге) —
-- используется и Магазином, и Тренировкой, чтобы не дублировать эту логику
-- в Dart на клиенте.
create or replace function public.list_word_packs()
returns table (
  level_index integer,
  pack_index integer,
  price integer,
  owned boolean,
  league_locked boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_elo integer;
  v_league_index integer;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select elo into v_elo from user_languages
    where user_id = v_uid and role = 'learning' and is_active = true;
  v_league_index := public.league_index_for_elo(coalesce(v_elo, 1000));

  return query
  select
    lvl.level_index,
    pk.pack_index,
    public.word_pack_price(lvl.level_index, pk.pack_index),
    (lvl.level_index = 0 and pk.pack_index = 0)
      or exists (
        select 1 from word_pack_purchases wpp
        where wpp.user_id = v_uid and wpp.level_index = lvl.level_index and wpp.pack_index = pk.pack_index
      ),
    lvl.level_index > v_league_index
  from generate_series(0, 5) as lvl(level_index)
  cross join generate_series(0, 9) as pk(pack_index)
  order by lvl.level_index, pk.pack_index;
end;
$$;

grant execute on function public.list_word_packs() to authenticated;

-- =========================================================================
-- 4. Монеты за изучение слов в Тренировке — раз в жизни на слово (не на
--    каждое нажатие "Знаю"), иначе игрок мог бы бесконечно фармить монеты,
--    листая один и тот же набор. Награда даётся именно за то, что слово
--    выучено ВПЕРВЫЕ — это единственное объективно проверяемое сервером
--    событие в чисто клиентской механике самооценки "Знаю"/"Не знаю".
-- =========================================================================

create table if not exists public.user_learned_words (
  user_id uuid not null references users(id) on delete cascade,
  level_index integer not null check (level_index between 0 and 5),
  word_index integer not null check (word_index between 0 and 999),
  learned_at timestamptz not null default now(),
  primary key (user_id, level_index, word_index)
);

alter table user_learned_words enable row level security;

drop policy if exists "user_learned_words: owner can view" on user_learned_words;
create policy "user_learned_words: owner can view"
  on user_learned_words for select
  to authenticated
  using (user_id = auth.uid());

create or replace function public.word_learn_reward()
returns integer
language sql
immutable
as $$ select 2; $$;

create or replace function public.mark_word_learned(p_level_index integer, p_word_index integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_coins integer := public.word_learn_reward();
  v_inserted boolean;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if p_level_index < 0 or p_level_index > 5 or p_word_index < 0 or p_word_index > 999 then
    raise exception 'invalid word';
  end if;

  insert into user_learned_words (user_id, level_index, word_index)
    values (v_uid, p_level_index, p_word_index)
    on conflict (user_id, level_index, word_index) do nothing;
  v_inserted := found;

  if v_inserted then
    update currency_wallets set soft_currency = soft_currency + v_coins where user_id = v_uid;
  end if;

  return jsonb_build_object('coins', case when v_inserted then v_coins else 0 end, 'already_known', not v_inserted);
end;
$$;

grant execute on function public.mark_word_learned(integer, integer) to authenticated;

grant select, insert, update, delete on all tables in schema public to authenticated;
