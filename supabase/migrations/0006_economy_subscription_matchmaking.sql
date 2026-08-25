-- Chrolingo — экономика (монеты + энергия), подписка, живой матчмейкинг,
-- группа на 2 игроков и пересчёт итога матча по выигранным раундам.
--
-- Правило подсчёта итога матча подтверждено владельцем проекта:
-- матч идёт РОВНО 10 раундов (rounds.round_number 1..10, как в исходной
-- схеме), но в шапке боя показывается не сумма баллов, а число выигранных
-- раундов — кто набрал в раунде больше баллов, тому +1. Сумма двух чисел в
-- шапке равна числу решённых раундов и на 10-м доходит до 10.
-- Ничейный раунд не даёт очка никому; если по выигранным раундам ничья —
-- победитель определяется по сумме баллов, и только при равенстве и там
-- матч считается ничьей.

-- =========================================================================
-- 1. Валюта: только монеты (раздел 2.6). Твёрдая валюта убирается совсем,
--    чтобы её нельзя было случайно начать использовать.
-- =========================================================================

alter table currency_wallets drop column if exists hard_currency;
alter table cosmetic_items drop column if exists price_hard;

alter table currency_wallets
  add column if not exists energy_current integer not null default 10,
  add column if not exists energy_max integer not null default 10,
  add column if not exists energy_last_regen_at timestamptz not null default now();

-- =========================================================================
-- 2. Подписка (раздел 2.6). При регистрации — пробные 7 дней.
--    Доступ к ЛЮБОМУ из трёх режимов требует активного trial или active.
--    Энергия — отдельное ограничение, подписка её не снимает.
-- =========================================================================

create table if not exists subscriptions (
  user_id uuid primary key references users(id) on delete cascade,
  status text not null check (status in ('trial','active','cancelled','expired')) default 'trial',
  trial_ends_at timestamptz,
  started_at timestamptz,
  expires_at timestamptz
);

alter table subscriptions enable row level security;

drop policy if exists "subscriptions: owner can view" on subscriptions;
create policy "subscriptions: owner can view"
  on subscriptions for select
  to authenticated
  using (user_id = auth.uid());

-- INSERT/UPDATE клиенту не выдаются намеренно: подписка меняется только
-- через activate_subscription() (security definer). Иначе игрок мог бы
-- проставить себе status='active' напрямую из приложения.

-- Существующим аккаунтам (заведённым до этой миграции) — тоже пробный
-- период, отсчитываемый от их даты регистрации.
insert into subscriptions (user_id, status, trial_ends_at)
select u.id, 'trial', u.created_at + interval '7 days'
from users u
on conflict (user_id) do nothing;

-- Бутстрап нового аккаунта: профиль + кошелёк + пробная подписка.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id) values (new.id);
  insert into public.currency_wallets (user_id) values (new.id);
  insert into public.subscriptions (user_id, status, trial_ends_at)
    values (new.id, 'trial', now() + interval '7 days');
  return new;
end;
$$;

-- has_game_access — единая точка правды "пустить ли игрока в режим".
create or replace function public.has_game_access(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from subscriptions s
    where s.user_id = p_user_id
      and (
        (s.status = 'trial' and s.trial_ends_at is not null and s.trial_ends_at > now())
        or (s.status = 'active' and (s.expires_at is null or s.expires_at > now()))
      )
  );
$$;

grant execute on function public.has_game_access(uuid) to authenticated;

-- activate_subscription — ЗАГЛУШКА платежа (осознанное временное решение,
-- см. промпт итерации): статус становится 'active' сразу по нажатию
-- "Оформить", без Google Play Billing / RevenueCat. Реальный платёжный
-- шлюз подключается отдельной задачей и заменит только тело этой функции.
create or replace function public.activate_subscription()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row subscriptions%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  insert into subscriptions (user_id, status, started_at, expires_at)
    values (v_uid, 'active', now(), now() + interval '30 days')
  on conflict (user_id) do update set
    status = 'active',
    started_at = coalesce(subscriptions.started_at, now()),
    -- Продление от текущей даты окончания, если подписка ещё не истекла.
    expires_at = greatest(coalesce(subscriptions.expires_at, now()), now()) + interval '30 days'
  returning * into v_row;

  return jsonb_build_object(
    'status', v_row.status,
    'expires_at', v_row.expires_at
  );
end;
$$;

grant execute on function public.activate_subscription() to authenticated;

-- =========================================================================
-- 3. Энергия: лимит попыток в Одиночной Игре. Восстанавливается со
--    временем (1 единица в 15 минут), считается на сервере — клиенту
--    нельзя доверять ни начисление, ни списание.
-- =========================================================================

create or replace function public.regen_energy(p_user_id uuid)
returns currency_wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wallet currency_wallets%rowtype;
  v_minutes integer;
  v_gained integer;
begin
  select * into v_wallet from currency_wallets where user_id = p_user_id for update;
  if not found then
    raise exception 'wallet not found for user %', p_user_id;
  end if;

  if v_wallet.energy_current >= v_wallet.energy_max then
    -- Полный запас: сдвигаем точку отсчёта, чтобы простой не копился.
    update currency_wallets set energy_last_regen_at = now()
      where user_id = p_user_id returning * into v_wallet;
    return v_wallet;
  end if;

  v_minutes := floor(extract(epoch from (now() - v_wallet.energy_last_regen_at)) / 60)::integer;
  v_gained := v_minutes / 15;
  if v_gained <= 0 then
    return v_wallet;
  end if;

  update currency_wallets set
    energy_current = least(energy_max, energy_current + v_gained),
    -- Остаток минут не сгорает: переносим его в новую точку отсчёта.
    energy_last_regen_at = energy_last_regen_at + make_interval(mins => v_gained * 15)
  where user_id = p_user_id
  returning * into v_wallet;

  return v_wallet;
end;
$$;

-- sync_wallet — то, что клиент дёргает при открытии Арены/Магазина:
-- досчитывает восстановленную энергию и отдаёт актуальный кошелёк.
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
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_wallet := public.regen_energy(v_uid);
  select * into v_sub from subscriptions where user_id = v_uid;

  return jsonb_build_object(
    'soft_currency', v_wallet.soft_currency,
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

-- =========================================================================
-- 4. Одиночная Игра: старт сессии — единственное место, где списывается
--    энергия, и там же проверяется подписка.
-- =========================================================================

create or replace function public.start_training_session(p_target_language text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_wallet currency_wallets%rowtype;
  v_elo integer;
  v_session_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if not public.has_game_access(v_uid) then
    raise exception 'subscription_required';
  end if;

  v_wallet := public.regen_energy(v_uid);
  if v_wallet.energy_current < 1 then
    raise exception 'no_energy';
  end if;

  update currency_wallets set energy_current = energy_current - 1 where user_id = v_uid;

  select elo into v_elo from user_languages
    where user_id = v_uid and language_code = p_target_language and role = 'learning'
    limit 1;

  insert into training_sessions (user_id, target_language, reference_elo)
    values (v_uid, p_target_language, coalesce(v_elo, 1000))
    returning id into v_session_id;

  return jsonb_build_object('session_id', v_session_id, 'reference_elo', coalesce(v_elo, 1000));
end;
$$;

grant execute on function public.start_training_session(text) to authenticated;

-- Журнал выданных наград — защита от повторного начисления за один раунд.
create table if not exists training_round_rewards (
  training_round_id uuid primary key references training_rounds(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  coins integer not null,
  granted_at timestamptz not null default now()
);

alter table training_round_rewards enable row level security;

drop policy if exists "training_round_rewards: owner can view" on training_round_rewards;
create policy "training_round_rewards: owner can view"
  on training_round_rewards for select
  to authenticated
  using (user_id = auth.uid());

-- Награда за пройденный раунд Одиночной Игры (валюта/опыт по разделу 2.2).
-- Начисляется только по факту выставленного сервером final_score — клиент
-- не может попросить награду за неоценённый раунд.
create or replace function public.claim_training_reward(p_training_round_id uuid)
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
    return jsonb_build_object('already_claimed', true);
  end if;

  v_coins := 3 * v_score;
  insert into training_round_rewards (training_round_id, user_id, coins) values (p_training_round_id, v_uid, v_coins);
  update currency_wallets set soft_currency = soft_currency + v_coins where user_id = v_uid;
  update users set xp = xp + v_score where id = v_uid;

  return jsonb_build_object('coins', v_coins, 'xp', v_score);
end;
$$;

grant execute on function public.claim_training_reward(uuid) to authenticated;

-- =========================================================================
-- 5. Каталог косметики (раздел 2.6 + задача 5 итерации).
--    Фильтр Магазина: Рамки = profile_frame, Эмоции = emote,
--    Аватар = avatar_skin. Предмет либо стоит монеты, либо помечен
--    subscriber_exclusive (тогда price_soft = NULL и метка "★ Подписка").
-- =========================================================================

alter table cosmetic_items
  add column if not exists subscriber_exclusive boolean not null default false,
  -- Слот редактора аватара для type='avatar_skin': hair/brows/eyes/lips/ears.
  -- Для остальных типов остаётся NULL.
  add column if not exists avatar_slot text
    check (avatar_slot is null or avatar_slot in ('hair','brows','eyes','lips','ears'));

-- Что из косметики надето на аватаре: {"hair": "<item_id>", "eyes": ...}.
-- Отдельная таблица тут была бы тяжелее, чем одна карта слот -> предмет.
alter table users add column if not exists equipped_avatar jsonb not null default '{}'::jsonb;

-- Старый набор из 0005 содержал цены в твёрдой валюте, которой больше нет —
-- пересобираем каталог целиком. Купленные предметы в user_inventory
-- сохраняются: id из 0005 переиспользуются, новые просто добавляются.
insert into cosmetic_items (id, name, type, price_soft, subscriber_exclusive, rarity, avatar_slot) values
  ('11111111-1111-1111-1111-111111111101', 'Золотое кольцо',   'profile_frame', null, true,  'epic', null),
  ('11111111-1111-1111-1111-111111111102', 'Неоновый обод',    'profile_frame', 320,  false, 'rare', null),
  ('11111111-1111-1111-1111-111111111103', 'Эмоция «Огонь»',   'emote',         90,   false, 'common', null),
  ('11111111-1111-1111-1111-111111111104', 'Эмоция «GG»',      'emote',         60,   false, 'common', null),
  ('11111111-1111-1111-1111-111111111105', 'Медный кант',      'profile_frame', 120,  false, 'common', null),
  ('11111111-1111-1111-1111-111111111106', 'Лавровый венок',   'profile_frame', 480,  false, 'epic', null),
  ('11111111-1111-1111-1111-111111111107', 'Хамелеон-рамка',   'profile_frame', null, true,  'legendary', null),
  ('11111111-1111-1111-1111-111111111108', 'Стальной обод',    'profile_frame', 200,  false, 'rare', null),
  ('11111111-1111-1111-1111-111111111109', 'Эмоция «Браво»',   'emote',         110,  false, 'common', null),
  ('11111111-1111-1111-1111-11111111110a', 'Эмоция «Думаю»',   'emote',         110,  false, 'common', null),
  ('11111111-1111-1111-1111-11111111110b', 'Эмоция «Полиглот»','emote',         null, true,  'epic', null),
  ('11111111-1111-1111-1111-11111111110c', 'Эмоция «Салют»',   'emote',         150,  false, 'rare', null),
  ('11111111-1111-1111-1111-11111111110d', 'Причёска «Ёж»',    'avatar_skin',   140,  false, 'common', 'hair'),
  ('11111111-1111-1111-1111-11111111110e', 'Причёска «Волна»', 'avatar_skin',   140,  false, 'common', 'hair'),
  ('11111111-1111-1111-1111-11111111110f', 'Брови «Дуга»',     'avatar_skin',   90,   false, 'common', 'brows'),
  ('11111111-1111-1111-1111-111111111110', 'Глаза «Искра»',    'avatar_skin',   210,  false, 'rare', 'eyes'),
  ('11111111-1111-1111-1111-111111111111', 'Губы «Ухмылка»',   'avatar_skin',   90,   false, 'common', 'lips'),
  ('11111111-1111-1111-1111-111111111112', 'Уши «Острые»',     'avatar_skin',   160,  false, 'rare', 'ears'),
  ('11111111-1111-1111-1111-111111111113', 'Глаза «Хамелеон»', 'avatar_skin',   null, true,  'legendary', 'eyes'),
  ('11111111-1111-1111-1111-111111111114', 'Причёска «Гребень»','avatar_skin',  260,  false, 'rare', 'hair')
on conflict (id) do update set
  name = excluded.name,
  type = excluded.type,
  price_soft = excluded.price_soft,
  subscriber_exclusive = excluded.subscriber_exclusive,
  rarity = excluded.rarity,
  avatar_slot = excluded.avatar_slot;

-- purchase_item: только монеты. Предмет с subscriber_exclusive не
-- продаётся — он "забирается" бесплатно, пока действует подписка/пробный
-- период (раздел 2.6: эксклюзив подписки, не отдельная покупка).
create or replace function public.purchase_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item cosmetic_items%rowtype;
  v_wallet currency_wallets%rowtype;
  v_uid uuid := auth.uid();
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
    select * into v_wallet from currency_wallets where user_id = v_uid for update;
    if not found then
      raise exception 'wallet not found for current user';
    end if;
    if v_wallet.soft_currency < v_item.price_soft then
      raise exception 'insufficient_funds';
    end if;
    update currency_wallets set soft_currency = soft_currency - v_item.price_soft where user_id = v_uid;
  end if;

  insert into user_inventory (user_id, item_id) values (v_uid, p_item_id)
    on conflict (user_id, item_id) do nothing;
end;
$$;

grant execute on function public.purchase_item(uuid) to authenticated;

-- =========================================================================
-- 6. Группа: максимум 2 игрока (задача 6 итерации).
-- =========================================================================

create table if not exists parties (
  id uuid primary key default gen_random_uuid(),
  leader_id uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists party_members (
  party_id uuid not null references parties(id) on delete cascade,
  -- unique на user_id: игрок может состоять максимум в одной группе.
  user_id uuid not null unique references users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (party_id, user_id)
);

create table if not exists party_invites (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references parties(id) on delete cascade,
  from_user_id uuid not null references users(id) on delete cascade,
  to_user_id uuid not null references users(id) on delete cascade,
  status text not null check (status in ('pending','accepted','declined','cancelled')) default 'pending',
  created_at timestamptz not null default now()
);

create index if not exists idx_party_invites_to_user on party_invites(to_user_id, status);

alter table parties enable row level security;
alter table party_members enable row level security;
alter table party_invites enable row level security;

drop policy if exists "parties: members can view" on parties;
create policy "parties: members can view"
  on parties for select
  to authenticated
  using (
    leader_id = auth.uid()
    or exists (select 1 from party_members pm where pm.party_id = parties.id and pm.user_id = auth.uid())
  );

drop policy if exists "party_members: co-members can view" on party_members;
create policy "party_members: co-members can view"
  on party_members for select
  to authenticated
  using (
    user_id = auth.uid()
    or exists (select 1 from party_members mine where mine.party_id = party_members.party_id and mine.user_id = auth.uid())
  );

drop policy if exists "party_invites: sender or recipient can view" on party_invites;
create policy "party_invites: sender or recipient can view"
  on party_invites for select
  to authenticated
  using (from_user_id = auth.uid() or to_user_id = auth.uid());

-- Запись в party_* — только через RPC ниже (нет insert/update policy):
-- иначе клиент мог бы затолкать в группу третьего участника.

create or replace function public.party_invite(p_friend_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_party_id uuid;
  v_size integer;
  v_invite_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if p_friend_id = v_uid then
    raise exception 'cannot invite yourself';
  end if;

  select party_id into v_party_id from party_members where user_id = v_uid;
  if v_party_id is null then
    insert into parties (leader_id) values (v_uid) returning id into v_party_id;
    insert into party_members (party_id, user_id) values (v_party_id, v_uid);
  end if;

  select count(*) into v_size from party_members where party_id = v_party_id;
  if v_size >= 2 then
    raise exception 'party_full';
  end if;
  if exists (select 1 from party_members where user_id = p_friend_id) then
    raise exception 'player_already_in_party';
  end if;

  insert into party_invites (party_id, from_user_id, to_user_id)
    values (v_party_id, v_uid, p_friend_id)
    returning id into v_invite_id;

  return jsonb_build_object('party_id', v_party_id, 'invite_id', v_invite_id);
end;
$$;

create or replace function public.party_accept(p_invite_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_invite party_invites%rowtype;
  v_size integer;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select * into v_invite from party_invites where id = p_invite_id for update;
  if not found or v_invite.to_user_id <> v_uid then
    raise exception 'invite not found';
  end if;
  if v_invite.status <> 'pending' then
    raise exception 'invite is no longer pending';
  end if;
  if exists (select 1 from party_members where user_id = v_uid) then
    raise exception 'player_already_in_party';
  end if;

  select count(*) into v_size from party_members where party_id = v_invite.party_id;
  if v_size >= 2 then
    update party_invites set status = 'cancelled' where id = p_invite_id;
    raise exception 'party_full';
  end if;

  insert into party_members (party_id, user_id) values (v_invite.party_id, v_uid);
  update party_invites set status = 'accepted' where id = p_invite_id;

  return jsonb_build_object('party_id', v_invite.party_id);
end;
$$;

create or replace function public.party_decline(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update party_invites set status = 'declined'
    where id = p_invite_id and to_user_id = auth.uid() and status = 'pending';
end;
$$;

create or replace function public.party_leave()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_party_id uuid;
begin
  select party_id into v_party_id from party_members where user_id = v_uid;
  if v_party_id is null then
    return;
  end if;

  delete from party_members where party_id = v_party_id and user_id = v_uid;
  update party_invites set status = 'cancelled'
    where party_id = v_party_id and status = 'pending';

  -- Группа из одного человека смысла не имеет — распускаем.
  if (select count(*) from party_members where party_id = v_party_id) <= 1 then
    delete from party_members where party_id = v_party_id;
    delete from parties where id = v_party_id;
  end if;
end;
$$;

grant execute on function public.party_invite(uuid) to authenticated;
grant execute on function public.party_accept(uuid) to authenticated;
grant execute on function public.party_decline(uuid) to authenticated;
grant execute on function public.party_leave() to authenticated;

-- =========================================================================
-- 7. Живой матчмейкинг (задача 3 итерации). Фоновый поиск с push и
--    бот-соперник в этот заход НЕ входят — при неудаче за 30 секунд
--    клиент просто показывает "соперник не найден".
-- =========================================================================

alter table matchmaking_tickets
  add column if not exists match_id uuid references matches(id) on delete set null,
  add column if not exists opponent_ticket_id uuid references matchmaking_tickets(id) on delete set null,
  add column if not exists accepted boolean not null default false;

drop policy if exists "matchmaking_tickets: owner can view" on matchmaking_tickets;
create policy "matchmaking_tickets: owner can view"
  on matchmaking_tickets for select
  to authenticated
  using (user_id = auth.uid());

-- Постановка в очередь. Один активный тикет на игрока: старые снимаются.
create or replace function public.mm_enqueue(
  p_game_mode text,
  p_native_language text,
  p_target_language text,
  p_countrymen_only boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_elo integer;
  v_ticket_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if not public.has_game_access(v_uid) then
    raise exception 'subscription_required';
  end if;

  update matchmaking_tickets set status = 'cancelled'
    where user_id = v_uid and status in ('searching','found');

  select elo into v_elo from user_languages
    where user_id = v_uid and language_code = p_target_language and role = 'learning'
    limit 1;

  insert into matchmaking_tickets (
    user_id, game_mode, native_language, target_language,
    countrymen_only, elo, status, expires_at
  ) values (
    v_uid, p_game_mode, p_native_language, p_target_language,
    coalesce(p_countrymen_only, false), coalesce(v_elo, 1000), 'searching', now() + interval '35 seconds'
  ) returning id into v_ticket_id;

  return v_ticket_id;
end;
$$;

-- Один шаг поиска. Клиент вызывает раз в пару секунд, расширяя окно ELO;
-- кто первым нашёл пару — тот и создаёт матч, второй узнаёт об этом через
-- Realtime на своём тикете. skip locked не даёт двум одновременным
-- вызовам схватить одного и того же соперника.
create or replace function public.mm_search(p_ticket_id uuid, p_elo_window integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_me matchmaking_tickets%rowtype;
  v_other matchmaking_tickets%rowtype;
  v_match_id uuid;
  v_language_pair text;
begin
  select * into v_me from matchmaking_tickets where id = p_ticket_id for update;
  if not found or v_me.user_id <> v_uid then
    raise exception 'ticket not found';
  end if;

  -- Соперника уже нашли (нас нашла встречная сторона) — отдаём матч.
  if v_me.status in ('found','accepted') and v_me.match_id is not null then
    return jsonb_build_object('found', true, 'match_id', v_me.match_id);
  end if;
  if v_me.status <> 'searching' then
    return jsonb_build_object('found', false, 'status', v_me.status);
  end if;
  if v_me.expires_at is not null and v_me.expires_at < now() then
    update matchmaking_tickets set status = 'expired' where id = p_ticket_id;
    return jsonb_build_object('found', false, 'status', 'expired');
  end if;

  select * into v_other
  from matchmaking_tickets t
  where t.status = 'searching'
    and t.id <> v_me.id
    and t.user_id <> v_me.user_id
    and t.game_mode = v_me.game_mode
    and (t.expires_at is null or t.expires_at > now())
    and abs(coalesce(t.elo, 1000) - coalesce(v_me.elo, 1000)) <= p_elo_window
    and (
      case v_me.game_mode
        -- Состязание: достаточно общего изучаемого языка. Тумблер
        -- "только соотечественники" уважается, если его включила любая
        -- из сторон.
        when 'sparring' then
          t.target_language = v_me.target_language
          and (
            (not v_me.countrymen_only and not t.countrymen_only)
            or t.native_language = v_me.native_language
          )
        -- Дуэль: строгая обратная пара.
        when 'native_duel' then
          t.target_language = v_me.native_language
          and t.native_language = v_me.target_language
        else false
      end
    )
  order by abs(coalesce(t.elo, 1000) - coalesce(v_me.elo, 1000)), t.created_at
  limit 1
  for update skip locked;

  if not found then
    return jsonb_build_object('found', false, 'status', 'searching');
  end if;

  if v_me.game_mode = 'native_duel' then
    -- Конвенция language_pair для Дуэли: "родной A - родной B"
    -- (см. supabase/README.md и MatchData.languageForSlot).
    v_language_pair := v_me.native_language || '-' || v_other.native_language;
  else
    v_language_pair := v_me.target_language;
  end if;

  insert into matches (player_a_id, player_b_id, game_mode, language_pair, status)
    values (v_uid, v_other.user_id, v_me.game_mode, v_language_pair, 'matchmaking')
    returning id into v_match_id;

  update matchmaking_tickets set
    status = 'found', match_id = v_match_id, opponent_ticket_id = v_other.id, notified_at = now()
    where id = v_me.id;
  update matchmaking_tickets set
    status = 'found', match_id = v_match_id, opponent_ticket_id = v_me.id, notified_at = now()
    where id = v_other.id;

  return jsonb_build_object('found', true, 'match_id', v_match_id);
end;
$$;

-- Принятие найденного матча. Матч стартует, когда приняли обе стороны.
create or replace function public.mm_accept(p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_me matchmaking_tickets%rowtype;
  v_other matchmaking_tickets%rowtype;
begin
  select * into v_me from matchmaking_tickets where id = p_ticket_id for update;
  if not found or v_me.user_id <> v_uid then
    raise exception 'ticket not found';
  end if;
  if v_me.match_id is null then
    raise exception 'no match to accept';
  end if;

  update matchmaking_tickets set status = 'accepted', accepted = true where id = p_ticket_id;

  select * into v_other from matchmaking_tickets where id = v_me.opponent_ticket_id;
  if found and v_other.accepted then
    update matches set status = 'in_progress'
      where id = v_me.match_id and status = 'matchmaking';
  end if;

  return jsonb_build_object(
    'match_id', v_me.match_id,
    'both_accepted', coalesce(v_other.accepted, false)
  );
end;
$$;

-- Отмена/отказ. Если матч уже был найден — он отменяется целиком, вторая
-- сторона просто увидит "соперник не найден" (фоновый поиск и возврат в
-- очередь — отдельная будущая задача, см. задачу 3 итерации).
create or replace function public.mm_cancel(p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_me matchmaking_tickets%rowtype;
begin
  select * into v_me from matchmaking_tickets where id = p_ticket_id for update;
  if not found or v_me.user_id <> v_uid then
    return;
  end if;

  update matchmaking_tickets set status = 'cancelled' where id = p_ticket_id;

  if v_me.match_id is not null then
    update matches set status = 'abandoned'
      where id = v_me.match_id and status = 'matchmaking';
    update matchmaking_tickets set status = 'cancelled', match_id = null
      where id = v_me.opponent_ticket_id and status in ('found','accepted');
  end if;
end;
$$;

grant execute on function public.mm_enqueue(text, text, text, boolean) to authenticated;
grant execute on function public.mm_search(uuid, integer) to authenticated;
grant execute on function public.mm_accept(uuid) to authenticated;
grant execute on function public.mm_cancel(uuid) to authenticated;

-- =========================================================================
-- 8. Battle Pass: "Очки Победы: X из 10" — шкала 0-10 за сезон, где очко
--    даётся за выигранный матч (раздел 2.6). tier и есть эти очки.
-- =========================================================================

insert into battle_pass_seasons (id, season_name, start_date, end_date)
values ('22222222-2222-2222-2222-222222222201', 'Сезон 1', current_date, current_date + 42)
on conflict (id) do nothing;

drop policy if exists "battle_pass_seasons: anyone authenticated can view" on battle_pass_seasons;
create policy "battle_pass_seasons: anyone authenticated can view"
  on battle_pass_seasons for select
  to authenticated
  using (true);

drop policy if exists "battle_pass_progress: owner can view" on battle_pass_progress;
create policy "battle_pass_progress: owner can view"
  on battle_pass_progress for select
  to authenticated
  using (user_id = auth.uid());

create or replace function public.current_season()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from battle_pass_seasons
  where start_date <= current_date and end_date >= current_date
  order by start_date desc
  limit 1;
$$;

grant execute on function public.current_season() to authenticated;

-- =========================================================================
-- 9. finalize_match — итог матча по ВЫИГРАННЫМ РАУНДАМ (подтверждённое
--    правило, см. шапку файла). Матч по-прежнему длится ровно 10 раундов.
-- =========================================================================

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
  v_elo_a integer;
  v_elo_b integer;
  v_k_a integer;
  v_k_b integer;
  v_expected_a numeric;
  v_actual_a numeric;
  v_change_a integer := 0;
  v_change_b integer := 0;
  v_matches_a integer;
  v_matches_b integer;
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

  if not v_match.is_bot_opponent then
    if v_match.game_mode = 'native_duel' then
      v_lang_a := split_part(v_match.language_pair, '-', 2);
      v_lang_b := split_part(v_match.language_pair, '-', 1);
    else
      v_lang_a := v_match.language_pair;
      v_lang_b := v_match.language_pair;
    end if;

    select elo into v_elo_a from user_languages
      where user_id = v_match.player_a_id and language_code = v_lang_a and role = 'learning' limit 1;
    select elo into v_elo_b from user_languages
      where user_id = v_match.player_b_id and language_code = v_lang_b and role = 'learning' limit 1;

    if v_elo_a is not null and v_elo_b is not null then
      select count(*) into v_matches_a from matches
        where status = 'completed' and not is_bot_opponent and (player_a_id = v_match.player_a_id or player_b_id = v_match.player_a_id);
      select count(*) into v_matches_b from matches
        where status = 'completed' and not is_bot_opponent and (player_a_id = v_match.player_b_id or player_b_id = v_match.player_b_id);
      v_k_a := case when v_matches_a < 30 then 32 else 16 end;
      v_k_b := case when v_matches_b < 30 then 32 else 16 end;

      v_expected_a := 1.0 / (1.0 + power(10.0, (v_elo_b - v_elo_a) / 400.0));
      v_actual_a := case when v_winner = v_match.player_a_id then 1.0
                          when v_winner is null then 0.5
                          else 0.0 end;

      v_change_a := round(v_k_a * (v_actual_a - v_expected_a));
      v_change_b := round(v_k_b * ((1.0 - v_actual_a) - (1.0 - v_expected_a)));

      update user_languages set elo = elo + v_change_a
        where user_id = v_match.player_a_id and language_code = v_lang_a and role = 'learning';
      update user_languages set elo = elo + v_change_b
        where user_id = v_match.player_b_id and language_code = v_lang_b and role = 'learning';
    end if;
  end if;

  update matches set
    status = 'completed',
    winner_id = v_winner,
    elo_change_a = v_change_a,
    elo_change_b = v_change_b,
    completed_at = now()
  where id = p_match_id;

  update currency_wallets set soft_currency = soft_currency + 50 where user_id = v_match.player_a_id;
  update currency_wallets set soft_currency = soft_currency + 50 where user_id = v_match.player_b_id;
  update users set xp = xp + 20 where id = v_match.player_a_id;
  update users set xp = xp + 20 where id = v_match.player_b_id;
  if v_winner is not null then
    update currency_wallets set soft_currency = soft_currency + 50 where user_id = v_winner;
    update users set xp = xp + 30 where id = v_winner;

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

grant execute on function public.finalize_match(uuid) to authenticated;

-- =========================================================================
-- 10. Гранты для таблиц, добавленных этой миграцией (см. 0003 — RLS
--     работает только поверх табличного GRANT).
-- =========================================================================

grant select, insert, update, delete on all tables in schema public to authenticated;

-- =========================================================================
-- 11. Экипировка: рамка, эмоция и части аватара (редактор аватара —
--     задача 5 итерации). Части аватара живут в users.equipped_avatar
--     как карта слот -> item_id.
-- =========================================================================

create or replace function public.equip_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item cosmetic_items%rowtype;
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if not exists (select 1 from user_inventory where user_id = v_uid and item_id = p_item_id) then
    raise exception 'item not owned';
  end if;

  select * into v_item from cosmetic_items where id = p_item_id;
  if not found then
    raise exception 'item % not found', p_item_id;
  end if;

  if v_item.type = 'profile_frame' then
    update users set equipped_frame_id = p_item_id where id = v_uid;
  elsif v_item.type = 'emote' then
    update users set equipped_emote_id = p_item_id where id = v_uid;
  elsif v_item.type = 'avatar_skin' then
    if v_item.avatar_slot is null then
      raise exception 'avatar item % has no slot', p_item_id;
    end if;
    update users
      set equipped_avatar = coalesce(equipped_avatar, '{}'::jsonb)
        || jsonb_build_object(v_item.avatar_slot, p_item_id::text)
      where id = v_uid;
  else
    raise exception 'item type % is not equippable yet', v_item.type;
  end if;
end;
$$;

grant execute on function public.equip_item(uuid) to authenticated;
