-- Весь прогресс принадлежит ИЗУЧАЕМОМУ ЯЗЫКУ, а не паре языков.
--
-- ЧТО БЫЛО. Строка user_languages с role='learning' была ПАРОЙ: ключом
-- служили оба языка (native_for + language_code), и у ru→en и es→en были
-- разные рейтинги. Монеты и опыт при этом лежали в одном месте на аккаунт
-- (currency_wallets.soft_currency, users.xp) — то есть рейтинг делился по
-- парам, а кошелёк был общим. Две разные системы учёта одного и того же
-- игрока.
--
-- ЧТО СТАЛО. Ключ один — изучаемый язык. У каждого изучаемого языка свои
-- рейтинг, лига, монеты, опыт и достижения; язык, НА КОТОРОМ игрок говорит,
-- остаётся при этой же строке (native_for), но ключом больше не является:
-- перестав переводить с русского и начав с английского, игрок не теряет
-- накопленное по английскому.
--
-- ЧТО ЭТО СТОИТ. Пары, отличавшиеся только языком-источником, схлопываются
-- в одну строку, и рейтинг остаётся от ЛУЧШЕЙ из них (активная в приоритете).
-- Данные при этом теряются — и лучше сказать это здесь прямо, чем оставить
-- в базе две строки, из которых одна навсегда недостижима.
--
-- ЭНЕРГИЯ И ПОДПИСКА ОСТАЮТСЯ НА АККАУНТЕ. Они не прогресс, а ограничитель
-- и оплата: делить их по языкам значило бы выдавать полный запас каждому,
-- кто завёл вторую пару.

-- =========================================================================
-- 1. Один изучаемый язык — одна строка
-- =========================================================================

-- Схлопываем дубликаты. Выживает активная, иначе самая сильная по
-- рейтингу: терять достижения игрока ради наведения порядка нельзя, а
-- выбрать из двух приходится.
with ranked as (
  select id,
         row_number() over (
           partition by user_id, language_code
           order by is_active desc, league_rating desc nulls last, id
         ) as rn
  from user_languages
  where role = 'learning'
)
delete from user_languages ul
using ranked r
where ul.id = r.id and r.rn > 1;

-- Ключ пары больше не ключ: изучаемый язык у игрока один на строку.
drop index if exists user_languages_pair_key;

create unique index if not exists user_languages_language_key
  on user_languages (user_id, role, language_code);

-- Активный изучаемый язык ровно один. Ни одного активного — берём лучший:
-- игрок с языками, но без выбранного, иначе не попадёт ни в один режим.
--
-- ДВУМЯ ЗАПРОСАМИ, А НЕ ОДНИМ: активный уникален (индекс
-- user_languages_one_active_learning), и единственный UPDATE, ставящий
-- одной строке true раньше, чем другой false, упал бы на этом индексе.
update user_languages set is_active = false where role = 'learning';

with ranked as (
  select id,
         row_number() over (
           partition by user_id
           order by hidden_at nulls first, league_rating desc nulls last, id
         ) as rn
  from user_languages
  where role = 'learning'
)
update user_languages ul
set is_active = true
from ranked r
where ul.id = r.id and r.rn = 1;

-- Строки role = 'native' не читает НИКТО. Их заводила регистрация «за
-- компанию», а родной язык при этом всё равно брался из
-- users.native_language — то есть один и тот же факт лежал в двух местах,
-- и второе место никто не обновлял. Убираем второе.
delete from user_languages where role = 'native';

-- =========================================================================
-- 2. Монеты и опыт переезжают к языку
-- =========================================================================

alter table user_languages add column if not exists coins integer not null default 0;
alter table user_languages add column if not exists xp integer not null default 0;

comment on column user_languages.coins is
  'Монеты, заработанные НА ЭТОМ изучаемом языке. Кошелёк на аккаунт '
  '(currency_wallets.soft_currency) удалён: две копии одного числа '
  'расходятся всегда.';
comment on column user_languages.xp is
  'Опыт по этому изучаемому языку. Прежний общий users.xp удалён.';

-- Накопленное отдаём активному языку: это тот, которым игрок играл.
update user_languages ul
set coins = coalesce(w.soft_currency, 0),
    xp = coalesce(u.xp, 0)
from users u
left join currency_wallets w on w.user_id = u.id
where ul.user_id = u.id
  and ul.role = 'learning'
  and ul.is_active;

-- Старые хранилища убираем совсем. Оставить их «на всякий случай» значит
-- завести второе место, где лежит золото, и однажды показать игроку не то.
alter table currency_wallets drop column if exists soft_currency;
alter table users drop column if exists xp;

-- =========================================================================
-- 3. Какой язык сейчас изучается
-- =========================================================================

-- Одна функция на все RPC ниже: «активный изучаемый язык игрока». Без неё
-- каждая писала бы этот запрос сама, и однажды одна из них выбрала бы
-- другую строку.
create or replace function public.active_learning_language(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select language_code
  from user_languages
  where user_id = p_user_id and role = 'learning' and hidden_at is null
  order by is_active desc, league_rating desc nulls last, id
  limit 1;
$$;

grant execute on function public.active_learning_language(uuid) to authenticated;

-- =========================================================================
-- 4. Выбор языков — одной функцией
-- =========================================================================

-- ПАР БОЛЬШЕ НЕТ, И ВЫБИРАТЬ ИХ НЕГДЕ. Игрок выбирает в настройках два
-- языка: на котором говорит и который учит. Прежние add/set_active/hide/
-- retarget решали задачу списка пар, которого не стало.
create or replace function public.set_my_languages(p_speaks text, p_learns text)
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
  if p_speaks is null or p_learns is null or btrim(p_speaks) = '' or btrim(p_learns) = '' then
    raise exception 'language_required';
  end if;
  if p_speaks = p_learns then
    raise exception 'target_equals_native';
  end if;

  -- Язык, на котором говорит игрок, — свойство аккаунта: он один и тот же
  -- для любого изучаемого.
  update users set native_language = p_speaks where id = v_uid;

  -- СНАЧАЛА ГАСИМ ПРЕЖНИЙ, ПОТОМ ЗАЖИГАЕМ НОВЫЙ. Порядок не косметика:
  -- активный изучаемый язык ровно один (user_languages_one_active_learning,
  -- миграция 0009), и вставка второго активного до снятия первого падает.
  update user_languages
  set is_active = false
  where user_id = v_uid and role = 'learning' and language_code <> p_learns;

  -- Строка изучаемого языка: заводим или возвращаем скрытую. Рейтинг и
  -- накопленное при этом НЕ трогаем — в этом вся суть привязки к языку.
  insert into user_languages (user_id, language_code, role, native_for, is_active)
  values (v_uid, p_learns, 'learning', p_speaks, true)
  on conflict (user_id, role, language_code)
  do update set native_for = excluded.native_for,
                is_active = true,
                hidden_at = null;

  -- Язык-источник у остальных строк тоже подтягиваем: он у игрока один.
  update user_languages
  set native_for = p_speaks
  where user_id = v_uid and role = 'learning';
end;
$$;

grant execute on function public.set_my_languages(text, text) to authenticated;

-- Функции списка пар больше некому звать.
drop function if exists public.add_language_pair(text, text);
drop function if exists public.set_active_language_pair(text, text);
drop function if exists public.hide_language_pair(text, text);
drop function if exists public.retarget_language_pair(text, text, text, text);

-- =========================================================================
-- 5. Экономика: начисляем и списываем у языка
-- =========================================================================

create or replace function public.sync_wallet()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_wallet currency_wallets%rowtype;
  v_sub subscriptions%rowtype;
  v_lang text;
  v_coins integer := 0;
  v_xp integer := 0;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_wallet := public.regen_energy(v_uid);
  select * into v_sub from subscriptions where user_id = v_uid;
  v_lang := public.active_learning_language(v_uid);
  if v_lang is not null then
    select coins, xp into v_coins, v_xp
    from user_languages
    where user_id = v_uid and role = 'learning' and language_code = v_lang;
  end if;

  return jsonb_build_object(
    -- Имя ключа прежнее: кошелёк переехал, а читатели у него те же.
    'soft_currency', coalesce(v_coins, 0),
    'xp', coalesce(v_xp, 0),
    'learning_language', v_lang,
    'energy_current', v_wallet.energy_current,
    'energy_max', v_wallet.energy_max,
    'energy_last_regen_at', v_wallet.energy_last_regen_at,
    'subscription_status', coalesce(v_sub.status, 'expired'),
    'trial_ends_at', v_sub.trial_ends_at,
    'expires_at', v_sub.expires_at,
    'has_access', public.has_game_access(v_uid)
  );
end;
$$;

grant execute on function public.sync_wallet() to authenticated;

-- Начисление КОНКРЕТНОМУ языку. Одна точка на все режимы: иначе каждый
-- считал бы «куда класть» сам.
--
-- ЯЗЫК ПЕРЕДАЁТСЯ ЯВНО, а не берётся активный: матч мог идти на языке,
-- который игрок успел сменить, пока соперник доигрывал. Награда
-- принадлежит тому языку, на котором её заработали.
create or replace function public.grant_language_reward(
  p_user_id uuid,
  p_language text,
  p_coins integer,
  p_xp integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is null or p_language is null then
    return; -- языка нет — начислять некуда, и это не ошибка вызова
  end if;
  update user_languages
  set coins = coins + greatest(0, coalesce(p_coins, 0)),
      xp = xp + greatest(0, coalesce(p_xp, 0))
  where user_id = p_user_id and role = 'learning' and language_code = p_language;
end;
$$;

-- КОРОТКОЙ ФОРМЫ БЕЗ ЯЗЫКА ЗДЕСЬ НАМЕРЕННО НЕТ. Две версии одной функции
-- с разным числом параметров живут в базе одновременно, и вызов по имени
-- становится неоднозначным (PGRST203). А главное — «начисли куда-нибудь»
-- это ровно та формулировка, из-за которой награда однажды уходит не тому
-- языку: пусть каждый вызывающий скажет, какому.

grant execute on function public.grant_language_reward(uuid, text, integer, integer) to authenticated;

/*
 * Награда за раунд Одиночной Игры.
 *
 * ФОРМУЛА ПРОСТАЯ НАСТОЛЬКО, ЧТОБЫ ЕЁ МОЖНО БЫЛО ПОСЧИТАТЬ В УМЕ: сколько
 * баллов, столько монет и столько же опыта. Было «три монеты за балл» —
 * число ниоткуда, и игрок не мог сверить награду с оценкой.
 *
 * ПОДСКАЗКИ БЬЮТ ПО ЗОЛОТУ ВДВОЕ СИЛЬНЕЕ, ЧЕМ ПО ОПЫТУ. Открыв всю фразу,
 * игрок не заработал ничего — перевод был не его. Но прочитать её вслух он
 * всё равно должен был, и чему-то при этом научился: опыт теряется лишь
 * наполовину от доли подсказок.
 */
create or replace function public.claim_training_reward(
  p_training_round_id uuid,
  p_hint_ratio double precision default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_score integer;
  v_owner uuid;
  v_coins integer;
  v_xp integer;
  v_ratio double precision := least(1.0, greatest(0.0, coalesce(p_hint_ratio, 0)));
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select tr.final_score, ts.user_id into v_score, v_owner
    from training_rounds tr
    join training_sessions ts on ts.id = tr.session_id
    where tr.id = p_training_round_id
    for update of tr;

  if v_owner is null or v_owner <> v_uid then
    raise exception 'not your training round';
  end if;
  if v_score is null then
    raise exception 'round is not scored yet';
  end if;
  if exists (select 1 from training_round_rewards where training_round_id = p_training_round_id) then
    return jsonb_build_object('already_claimed', true, 'coins', 0, 'xp', 0);
  end if;

  v_coins := round(v_score * (1.0 - v_ratio))::integer;
  v_xp := round(v_score * (1.0 - 0.5 * v_ratio))::integer;

  -- Доля подсказок хранится в самом раунде, а не только в награде: по ней
  -- потом видно, как игрок проходил уровень, даже если награда не выдана.
  update training_rounds set hint_ratio = v_ratio where id = p_training_round_id;

  insert into training_round_rewards (training_round_id, user_id, coins)
    values (p_training_round_id, v_uid, v_coins);
  perform public.grant_language_reward(
    v_uid, public.active_learning_language(v_uid), v_coins, v_xp);

  return jsonb_build_object('coins', v_coins, 'xp', v_xp, 'hint_ratio', v_ratio);
end;
$$;

grant execute on function public.claim_training_reward(uuid, double precision) to authenticated;

-- Покупка косметики тратит монеты ТОГО ЖЕ языка, на котором заработаны.
create or replace function public.purchase_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item cosmetic_items%rowtype;
  v_uid uuid := auth.uid();
  v_lang text;
  v_coins integer;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from user_inventory where user_id = v_uid and item_id = p_item_id) then
    raise exception 'item already owned';
  end if;

  select * into v_item from cosmetic_items where id = p_item_id;
  if not found then
    raise exception 'item % not found', p_item_id;
  end if;

  if v_item.subscriber_exclusive then
    if not public.has_game_access(v_uid) then
      raise exception 'subscription_required';
    end if;
  else
    if v_item.price_soft is null then
      raise exception 'item % is not for sale', p_item_id;
    end if;
    v_lang := public.active_learning_language(v_uid);
    if v_lang is null then
      raise exception 'no_learning_language';
    end if;
    select coins into v_coins
      from user_languages
      where user_id = v_uid and role = 'learning' and language_code = v_lang
      for update;
    if coalesce(v_coins, 0) < v_item.price_soft then
      raise exception 'insufficient_funds';
    end if;
    update user_languages
      set coins = coins - v_item.price_soft
      where user_id = v_uid and role = 'learning' and language_code = v_lang;
  end if;

  insert into user_inventory (user_id, item_id) values (v_uid, p_item_id)
    on conflict (user_id, item_id) do nothing;
end;
$$;

grant execute on function public.purchase_item(uuid) to authenticated;

-- =========================================================================
-- 6. Достижения тоже принадлежат языку
-- =========================================================================

-- У каждого изучаемого языка свои достижения. Иначе «Покоритель» за десять
-- побед на английском висел бы и на только что начатом испанском — то есть
-- рассказывал бы про игрока неправду.
alter table public.achievements
  add column if not exists language_code text;

-- Уже выданные ступени отдаём активному языку: другого мы про них не знаем.
update public.achievements a
set language_code = public.active_learning_language(a.user_id)
where a.language_code is null;

-- Игрок без языков нам здесь не помощник: достижение без языка больше
-- некуда деть, а строка с null сломала бы ключ.
delete from public.achievements where language_code is null;

alter table public.achievements alter column language_code set not null;

alter table public.achievements drop constraint if exists achievements_pkey;
alter table public.achievements
  add constraint achievements_pkey primary key (user_id, kind, language_code, tier);

-- Список видов растёт и НЕ УМЕНЬШАЕТСЯ: выбросив значение из CHECK, мы
-- сломали бы строки, которые у игроков уже есть.
alter table public.achievements drop constraint if exists achievements_kind_check;
alter table public.achievements
  add constraint achievements_kind_check
  check (kind in ('unstoppable', 'conqueror', 'auditor', 'scholar', 'social'));

/*
 * Ступени, заслуженные числом p_count. ЛЕСТНИЦА ОПИСАНА ЗДЕСЬ ОДИН РАЗ —
 * и сервером, который выдаёт, и клиентом, который рисует серую плашку
 * «сделай n», она читается из одного места (см. lib/data/achievements.dart:
 * там та же лестница продублирована в Dart и обязана совпадать).
 *
 * ПЕРВАЯ СТУПЕНЬ У «Покорителя» И «Аудитора» — ЕДИНИЦА. Первая победа и
 * первая прослушанная запись носителя — это события, которые игрок и сам
 * запомнит; отметить их дешевле, чем ждать пятой.
 */
create or replace function public.achievement_tiers_reached(p_kind text, p_count integer)
returns integer[]
language plpgsql
immutable
as $$
declare
  v_tiers integer[] := '{}';
  v_t integer;
begin
  if p_count is null or p_count < 1 then
    return v_tiers;
  end if;

  if p_kind = 'unstoppable' then
    -- 5, 10, 15 … — раунды подряд в Одиночной Игре
    v_t := 5;
    while v_t <= p_count loop
      v_tiers := v_tiers || v_t;
      v_t := v_t + 5;
    end loop;
  elsif p_kind in ('conqueror', 'auditor') then
    -- 1, 5, 10, 15 …
    v_tiers := v_tiers || 1;
    v_t := 5;
    while v_t <= p_count loop
      v_tiers := v_tiers || v_t;
      v_t := v_t + 5;
    end loop;
  elsif p_kind = 'scholar' then
    -- 10, 20, 30 … — слова учат десятками, и шаг тут крупнее
    v_t := 10;
    while v_t <= p_count loop
      v_tiers := v_tiers || v_t;
      v_t := v_t + 10;
    end loop;
  elsif p_kind = 'social' then
    -- 1, 3, 5, 10 и всё: собеседников не бывает бесконечно много, и
    -- бесконечная лестница здесь превратилась бы в требование добавлять
    -- людей ради счётчика.
    foreach v_t in array array[1, 3, 5, 10] loop
      if v_t <= p_count then
        v_tiers := v_tiers || v_t;
      end if;
    end loop;
  else
    raise exception 'unknown achievement kind %', p_kind;
  end if;

  return v_tiers;
end;
$$;

grant execute on function public.achievement_tiers_reached(text, integer) to authenticated;

/*
 * Выдаёт все ступени вида p_kind, заслуженные числом p_count, и возвращает
 * ТОЛЬКО НОВЫЕ — их и показывает игроку клиент.
 *
 * ВЫДАЁТ СРАЗУ ВСЕ НЕДОСТАЮЩИЕ, а не только последнюю: игрок мог дойти до
 * пятой победы в тот момент, когда приложение потеряло сеть, и вернуться к
 * нам уже на одиннадцатой. Пропущенная пятёрка от этого не перестаёт быть
 * заслуженной.
 *
 * ИДЕМПОТЕНТНА: повторный вызов с тем же числом не выдаёт ничего.
 */
create or replace function public.award_achievement(
  p_user_id uuid,
  p_kind text,
  p_language text,
  p_count integer
)
returns integer[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new integer[];
begin
  if p_user_id is null or p_language is null then
    return '{}';
  end if;

  with earned as (
    insert into achievements (user_id, kind, language_code, tier)
    select p_user_id, p_kind, p_language, t
    from unnest(public.achievement_tiers_reached(p_kind, p_count)) as t
    on conflict (user_id, kind, language_code, tier) do nothing
    returning tier
  )
  select coalesce(array_agg(tier order by tier), '{}') into v_new from earned;

  return v_new;
end;
$$;

-- =========================================================================
-- 6.1. «Неудержимый» — раунды подряд в Одиночной Игре
-- =========================================================================

-- Тело переехало в общий award_achievement; сигнатура прежняя, потому что
-- клиент зовёт её так же.
create or replace function public.award_unstoppable(p_rounds integer)
returns jsonb
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
  return jsonb_build_object(
    'new_tiers',
    to_jsonb(public.award_achievement(
      v_uid, 'unstoppable', public.active_learning_language(v_uid), p_rounds))
  );
end;
$$;

drop function if exists public.unstoppable_step();

-- =========================================================================
-- 6.2. «Покоритель» — победы в PvP
-- =========================================================================

-- На каком изучаемом языке игрок провёл этот матч. В Состязании оба играют
-- на одном языке, в Дуэли — каждый на своём (см. finalize_match).
create or replace function public.match_language_for(p_match matches, p_user_id uuid)
returns text
language sql
immutable
as $$
  select case
    when p_match.game_mode = 'native_duel' then
      case when p_match.player_a_id = p_user_id
        then split_part(p_match.language_pair, '-', 2)
        else split_part(p_match.language_pair, '-', 1)
      end
    else p_match.language_pair
  end;
$$;

-- Победы считаются ПО ТАБЛИЦЕ МАТЧЕЙ, а не отдельным счётчиком. Счётчик
-- пришлось бы чинить после каждого сбоя; здесь же число всегда ровно то,
-- что игрок действительно выиграл.
--
-- БОТЫ НЕ В СЧЁТ: победа над ботом выдаётся по требованию, и достижение за
-- неё ничего не значило бы.
create or replace function public.pvp_wins(p_user_id uuid, p_language text)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from matches m
  where m.status = 'completed'
    and m.winner_id = p_user_id
    and not m.is_bot_opponent
    and public.match_language_for(m, p_user_id) = p_language;
$$;

grant execute on function public.pvp_wins(uuid, text) to authenticated;

-- =========================================================================
-- 6.3. «Аудитор» — прослушанные записи носителей изучаемого языка
-- =========================================================================

-- Одна строка на запись, а не счётчик нажатий: переслушав ответ соперника
-- трижды, игрок не прослушал трёх носителей.
create table if not exists public.voice_listens (
  user_id uuid not null references public.users(id) on delete cascade,
  recording_id uuid not null references public.voice_recordings(id) on delete cascade,
  -- Изучаемый язык слушателя на момент прослушивания: сменив язык, он не
  -- должен унести с собой чужой прогресс.
  language_code text not null,
  listened_at timestamptz not null default now(),
  primary key (user_id, recording_id)
);

create index if not exists idx_voice_listens_user on public.voice_listens(user_id, language_code);

alter table public.voice_listens enable row level security;

drop policy if exists voice_listens_select_own on public.voice_listens;
create policy voice_listens_select_own on public.voice_listens
  for select using (user_id = auth.uid());

/*
 * Отмечает прослушанную запись и возвращает новые ступени «Аудитора».
 *
 * ЗАСЧИТЫВАЕТСЯ НЕ ЛЮБАЯ ЗАПИСЬ. Нужно, чтобы (1) говорил кто-то другой,
 * (2) он был НОСИТЕЛЕМ языка, который слушатель изучает, и (3) слушатель
 * имел к этой записи доступ — то есть был участником того же матча. Без
 * третьей проверки достижение выдавалось бы за id, подобранный наугад.
 *
 * НИЧЕГО НЕ ЛОМАЕТ при отказе: не засчиталось — вернёт нули.
 */
create or replace function public.note_voice_listen(p_recording_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lang text;
  v_rec voice_recordings%rowtype;
  v_speaker_native text;
  v_match uuid;
  v_total integer;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_lang := public.active_learning_language(v_uid);
  if v_lang is null then
    return jsonb_build_object('counted', false, 'total', 0, 'new_tiers', '[]'::jsonb);
  end if;

  select * into v_rec from voice_recordings where id = p_recording_id;
  if not found or v_rec.user_id = v_uid then
    return jsonb_build_object('counted', false, 'total', 0, 'new_tiers', '[]'::jsonb);
  end if;

  select r.match_id into v_match from rounds r where r.id = v_rec.round_id;
  if v_match is null or not public.is_match_participant(v_match, v_uid) then
    return jsonb_build_object('counted', false, 'total', 0, 'new_tiers', '[]'::jsonb);
  end if;

  select native_language into v_speaker_native from users where id = v_rec.user_id;
  if v_speaker_native is distinct from v_lang then
    return jsonb_build_object('counted', false, 'total', 0, 'new_tiers', '[]'::jsonb);
  end if;

  insert into voice_listens (user_id, recording_id, language_code)
    values (v_uid, p_recording_id, v_lang)
    on conflict (user_id, recording_id) do nothing;

  select count(*)::integer into v_total
    from voice_listens where user_id = v_uid and language_code = v_lang;

  return jsonb_build_object(
    'counted', true,
    'total', v_total,
    'new_tiers', to_jsonb(public.award_achievement(v_uid, 'auditor', v_lang, v_total))
  );
end;
$$;

grant execute on function public.note_voice_listen(uuid) to authenticated;

-- =========================================================================
-- 6.4. «Знаток» — слова, выученные в Тренировке
-- =========================================================================

-- Слово засчитывается РАЗ В ЖИЗНИ. Иначе игрок, раз за разом отмечающий
-- одно и то же слово незнакомым, получил бы все ступени за один вечер.
create table if not exists public.training_learned_words (
  user_id uuid not null references public.users(id) on delete cascade,
  language_code text not null,
  -- Ключ слова из глоссария (см. lib/data/phrase_glossary.dart): само
  -- слово в нижнем регистре. Хранить перевод не нужно — он в ассетах.
  word text not null,
  learned_at timestamptz not null default now(),
  primary key (user_id, language_code, word)
);

alter table public.training_learned_words enable row level security;

drop policy if exists training_learned_words_select_own on public.training_learned_words;
create policy training_learned_words_select_own on public.training_learned_words
  for select using (user_id = auth.uid());

-- Отмечает выученные в Тренировке слова и возвращает новые ступени
-- «Знатока». Принимает сразу пачку: карточки проходят колодой, и звать
-- сервер на каждое слово значило бы двадцать запросов вместо одного.
create or replace function public.note_learned_words(p_words text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lang text;
  v_total integer;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_lang := public.active_learning_language(v_uid);
  if v_lang is null or p_words is null then
    return jsonb_build_object('total', 0, 'new_tiers', '[]'::jsonb);
  end if;

  insert into training_learned_words (user_id, language_code, word)
  select v_uid, v_lang, lower(btrim(w))
  from unnest(p_words) as w
  where btrim(coalesce(w, '')) <> ''
  on conflict (user_id, language_code, word) do nothing;

  select count(*)::integer into v_total
    from training_learned_words where user_id = v_uid and language_code = v_lang;

  return jsonb_build_object(
    'total', v_total,
    'new_tiers', to_jsonb(public.award_achievement(v_uid, 'scholar', v_lang, v_total))
  );
end;
$$;

grant execute on function public.note_learned_words(text[]) to authenticated;

-- =========================================================================
-- 6.5. «Социальный» — общение с игроками изучаемого языка
-- =========================================================================

/*
 * Считает, скольким игрокам, связанным с изучаемым языком, игрок НАПИСАЛ
 * первым, и выдаёт ступени «Социального».
 *
 * СЧИТАЮТСЯ ОТПРАВЛЕННЫЕ СООБЩЕНИЯ, А НЕ ПОЛУЧЕННЫЕ: достижение называется
 * «начать общение», и начинает его тот, кто написал.
 *
 * «ИГРОК ИЗУЧАЕМОГО ЯЗЫКА» — тот, для кого этот язык родной ИЛИ кто его
 * учит. Второе здесь не послабление: товарищ по языку — такой же
 * собеседник, и разговор с ним ровно так же на этом языке.
 */
create or replace function public.sync_social_achievement()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lang text;
  v_total integer;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_lang := public.active_learning_language(v_uid);
  if v_lang is null then
    return jsonb_build_object('total', 0, 'new_tiers', '[]'::jsonb);
  end if;

  select count(distinct dm.recipient_id)::integer into v_total
  from direct_messages dm
  where dm.sender_id = v_uid
    and (
      exists (select 1 from users u
              where u.id = dm.recipient_id and u.native_language = v_lang)
      or exists (select 1 from user_languages ul
                 where ul.user_id = dm.recipient_id
                   and ul.role = 'learning'
                   and ul.language_code = v_lang)
    );

  return jsonb_build_object(
    'total', v_total,
    'new_tiers', to_jsonb(public.award_achievement(v_uid, 'social', v_lang, v_total))
  );
end;
$$;

grant execute on function public.sync_social_achievement() to authenticated;

-- =========================================================================
-- 7. PvP: награда идёт языку, на котором играли
-- =========================================================================

-- Тело скопировано из 0026, изменён только блок наград: монеты и опыт
-- больше не лежат на аккаунте, и класть их надо ТОМУ ЯЗЫКУ, на котором
-- матч шёл, — не активному на момент подсчёта. Соперник мог доигрывать
-- час, за который победитель успел сменить язык.
create or replace function public.finalize_match(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match matches%rowtype;
  v_wins_a integer := 0;
  v_wins_b integer := 0;
  v_total_a integer := 0;
  v_total_b integer := 0;
  v_round_count integer;
  v_scored_rounds integer;
  v_winner uuid;
  v_lang_a text;
  v_lang_b text;
  v_score_a double precision;
  v_change_a integer := 0;
  v_change_b integer := 0;
  v_season uuid;
begin
  select * into v_match from matches where id = p_match_id for update;
  if not found then
    raise exception 'match % not found', p_match_id;
  end if;
  if auth.uid() is distinct from v_match.player_a_id and auth.uid() is distinct from v_match.player_b_id then
    raise exception 'not a participant of this match';
  end if;

  if v_match.status = 'completed' then
    return jsonb_build_object('already_completed', true, 'winner_id', v_match.winner_id);
  end if;
  if v_match.status <> 'in_progress' then
    raise exception 'match % is not in_progress', p_match_id;
  end if;

  select count(*) into v_round_count from rounds where match_id = p_match_id;
  select count(*) into v_scored_rounds
    from rounds r
    where r.match_id = p_match_id
      and exists (select 1 from round_scores s where s.round_id = r.id and s.user_id = v_match.player_a_id and s.score is not null)
      and exists (select 1 from round_scores s where s.round_id = r.id and s.user_id = v_match.player_b_id and s.score is not null);

  if v_round_count < 10 or v_scored_rounds < 10 then
    raise exception 'match % is not fully scored yet (% / 10 rounds scored)', p_match_id, v_scored_rounds;
  end if;

  -- Очки шапки: раунд достаётся тому, кто набрал в нём больше баллов.
  -- Ничейный раунд не даёт очка никому.
  select
    count(*) filter (where sa.score > sb.score),
    count(*) filter (where sb.score > sa.score),
    coalesce(sum(sa.score), 0),
    coalesce(sum(sb.score), 0)
  into v_wins_a, v_wins_b, v_total_a, v_total_b
  from rounds r
  join round_scores sa on sa.round_id = r.id and sa.user_id = v_match.player_a_id
  join round_scores sb on sb.round_id = r.id and sb.user_id = v_match.player_b_id
  where r.match_id = p_match_id;

  if v_wins_a > v_wins_b then
    v_winner := v_match.player_a_id;
  elsif v_wins_b > v_wins_a then
    v_winner := v_match.player_b_id;
  -- Равенство по раундам — решает сумма баллов; равенство и там = ничья.
  elsif v_total_a > v_total_b then
    v_winner := v_match.player_a_id;
  elsif v_total_b > v_total_a then
    v_winner := v_match.player_b_id;
  else
    v_winner := null;
  end if;

  -- Язык каждого считаем ВСЕГДА, а не только в рейтинговом матче: награда
  -- за бой с ботом тоже должна знать, какому языку её класть.
  v_lang_a := public.match_language_for(v_match, v_match.player_a_id);
  v_lang_b := public.match_language_for(v_match, v_match.player_b_id);

  if not v_match.is_bot_opponent then
    -- Счёт матча: 1 — победа A, 0.5 — ничья, 0 — победа B.
    v_score_a := case when v_winner = v_match.player_a_id then 1.0
                      when v_winner is null then 0.5
                      else 0.0 end;
    select change_a, change_b into v_change_a, v_change_b
      from public.apply_elo_match(
        v_match.player_a_id, v_lang_a,
        v_match.player_b_id, v_lang_b,
        v_score_a, 1.0);
  end if;

  update matches set
    status = 'completed',
    winner_id = v_winner,
    elo_change_a = v_change_a,
    elo_change_b = v_change_b,
    completed_at = now()
  where id = p_match_id;

  perform public.grant_language_reward(v_match.player_a_id, v_lang_a, 50, 20);
  perform public.grant_language_reward(v_match.player_b_id, v_lang_b, 50, 20);
  if v_winner is not null then
    perform public.grant_language_reward(
      v_winner,
      case when v_winner = v_match.player_a_id then v_lang_a else v_lang_b end,
      50, 30);

    -- Очко Победы в Battle Pass (шкала 0-10 за сезон).
    v_season := public.current_season();
    if v_season is not null then
      insert into battle_pass_progress (user_id, season_id, xp, tier, has_premium)
        values (v_winner, v_season, 0, 1, public.has_game_access(v_winner))
      on conflict (user_id, season_id) do update set
        tier = least(10, battle_pass_progress.tier + 1),
        has_premium = public.has_game_access(v_winner);
    end if;
  end if;

  return jsonb_build_object(
    'winner_id', v_winner,
    'round_wins_a', v_wins_a,
    'round_wins_b', v_wins_b,
    'total_a', v_total_a,
    'total_b', v_total_b,
    'elo_change_a', v_change_a,
    'elo_change_b', v_change_b
  );
end;
$$;

/*
 * «Покоритель» выдаётся ТРИГГЕРОМ на завершение матча, а не из
 * finalize_match.
 *
 * ПОЧЕМУ ТРИГГЕР. Матч завершают две разные функции — finalize_match и
 * forfeit_match (выход соперника тоже победа). Скопировав выдачу в обе, мы
 * завели бы два места, которые обязаны совпадать, и однажды они разошлись
 * бы. Триггер видит один и тот же переход в 'completed' из любой из них.
 */
create or replace function public.award_conqueror_on_match_end()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lang text;
begin
  if new.status <> 'completed' or old.status = 'completed' then
    return new;
  end if;
  if new.winner_id is null or new.is_bot_opponent then
    return new;
  end if;

  v_lang := public.match_language_for(new, new.winner_id);
  if v_lang is null or v_lang = '' then
    return new;
  end if;

  perform public.award_achievement(
    new.winner_id, 'conqueror', v_lang, public.pvp_wins(new.winner_id, v_lang));
  return new;
end;
$$;

drop trigger if exists trg_award_conqueror on public.matches;
create trigger trg_award_conqueror
  after update of status on public.matches
  for each row execute function public.award_conqueror_on_match_end();

-- =========================================================================
-- 8. Наборы слов: остатки прежней Тренировки
-- =========================================================================

-- Наборы слов убраны из Магазина вместе со старой Тренировкой, и звать эти
-- функции больше некому. Две из них к тому же списывали и начисляли
-- удалённый currency_wallets.soft_currency — то есть сломались бы при
-- первом же вызове. Таблицы покупок и выученных слов оставлены: в них
-- лежит то, за что игроки платили, и стирать это ради порядка нельзя.
drop function if exists public.purchase_word_pack(integer, integer);
drop function if exists public.list_word_packs();
drop function if exists public.mark_word_learned(integer, integer);
drop function if exists public.word_learn_reward();
drop function if exists public.word_pack_price(integer, integer);

comment on table public.word_pack_purchases is
  'НЕ ИСПОЛЬЗУЕТСЯ с миграции 0051: наборы слов убраны из Магазина. '
  'Таблица оставлена как след оплаченных покупок.';
comment on table public.user_learned_words is
  'НЕ ИСПОЛЬЗУЕТСЯ с миграции 0051: слова Тренировки теперь в '
  'training_learned_words (по слову, а не по индексу в банке).';
