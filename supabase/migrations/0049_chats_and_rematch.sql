-- Чаты и реванш: мини-чат на экране итогов, переписка с друзьями и
-- повторный бой с тем же соперником.
--
-- ЗАЧЕМ ТРИ ТАБЛИЦЫ, А НЕ ОДНА. Мини-чат матча и переписка с другом
-- выглядят одинаково, но живут по разным правилам доступа и разное время.
-- Чат матча видят ровно двое участников этого матча, и умирает он вместе с
-- матчем (on delete cascade). Переписка с другом живёт, пока живут оба
-- аккаунта, и читают её двое, которые могут вообще ни разу не встретиться в
-- бою. Сведи их в одну таблицу — и политику доступа пришлось бы писать
-- через «или», то есть на каждой строке проверять оба правила сразу.
--
-- ЧЕГО ЗДЕСЬ НЕТ НАМЕРЕННО: удаления и редактирования сообщений. Их никто
-- не просил, а любая такая возможность требует отдельного решения о том,
-- что видит вторая сторона.

-- =========================================================================
-- 1. Мини-чат матча
-- =========================================================================

create table if not exists public.match_chat_messages (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  -- Текст сообщения. Для 'rematch' это «Реванш!», для 'rematch_started' —
  -- подпись о начатом бое: клиенту не нужно знать наши тексты наизусть.
  body text not null check (char_length(btrim(body)) between 1 and 500),
  -- 'text' — обычное сообщение или эмодзи (эмодзи это тот же текст);
  -- 'rematch' — вызов на реванш;
  -- 'rematch_started' — реванш принят, бой создан (id в new_match_id).
  kind text not null default 'text' check (kind in ('text', 'rematch', 'rematch_started')),
  new_match_id uuid references public.matches(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_match_chat_match on public.match_chat_messages(match_id, created_at);

alter table public.match_chat_messages enable row level security;

-- Участник матча — единственный, кто здесь что-то может. Проверка одна и та
-- же на чтение и на запись, поэтому вынесена в функцию: разъехавшись, эти
-- два условия однажды дали бы чат, который видно, но в который не написать.
create or replace function public.is_match_participant(p_match_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from matches m
    where m.id = p_match_id
      and p_user_id in (m.player_a_id, m.player_b_id)
  );
$$;

grant execute on function public.is_match_participant(uuid, uuid) to authenticated;

drop policy if exists match_chat_select on public.match_chat_messages;
create policy match_chat_select on public.match_chat_messages
  for select using (public.is_match_participant(match_id, auth.uid()));

-- Писать можно только от своего имени и только в свой матч. Первое без
-- второго позволило бы написать в чужой бой, второе без первого — написать
-- в своём бою от лица соперника.
drop policy if exists match_chat_insert on public.match_chat_messages;
create policy match_chat_insert on public.match_chat_messages
  for insert with check (
    user_id = auth.uid()
    and public.is_match_participant(match_id, auth.uid())
    -- 'rematch_started' пишет только функция реванша (security definer):
    -- сообщение о начатом бое несёт его id, и подделать его клиентом
    -- значило бы увести соперника в чужой матч.
    and kind in ('text', 'rematch')
  );

-- =========================================================================
-- 2. Переписка с друзьями
-- =========================================================================

create table if not exists public.direct_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.users(id) on delete cascade,
  recipient_id uuid not null references public.users(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default now(),
  -- Себе не пишем: чат с самим собой выглядел бы как ошибка интерфейса.
  constraint direct_messages_not_self check (sender_id <> recipient_id)
);

create index if not exists idx_dm_pair on public.direct_messages(sender_id, recipient_id, created_at);
create index if not exists idx_dm_inbox on public.direct_messages(recipient_id, created_at);

alter table public.direct_messages enable row level security;

drop policy if exists direct_messages_select on public.direct_messages;
create policy direct_messages_select on public.direct_messages
  for select using (auth.uid() in (sender_id, recipient_id));

-- ПИСАТЬ МОЖНО ТОЛЬКО ДРУГУ. Без этого условия любой знающий id писал бы
-- кому угодно, а чат с друзьями превратился бы в открытые личные сообщения
-- всему приложению.
drop policy if exists direct_messages_insert on public.direct_messages;
create policy direct_messages_insert on public.direct_messages
  for insert with check (
    sender_id = auth.uid()
    and exists (
      select 1 from friendships f
      where f.status = 'accepted'
        and (
          (f.user_id = auth.uid() and f.friend_id = recipient_id)
          or (f.user_id = recipient_id and f.friend_id = auth.uid())
        )
    )
  );

-- =========================================================================
-- 3. Закреплённые собеседники
-- =========================================================================
--
-- Лента аватарок сверху чата двигается сама: кто написал последним, тот
-- левее. Закрепление — единственный способ удержать нужного человека на
-- месте, и хранится оно у КАЖДОГО своё: мой закреплённый друг не должен
-- становиться закреплённым у него.

create table if not exists public.friend_chat_pins (
  user_id uuid not null references public.users(id) on delete cascade,
  friend_id uuid not null references public.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id)
);

alter table public.friend_chat_pins enable row level security;

drop policy if exists friend_chat_pins_own on public.friend_chat_pins;
create policy friend_chat_pins_own on public.friend_chat_pins
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- =========================================================================
-- 4. Реванш
-- =========================================================================
--
-- Реванш это НЕ приглашение в очередь подбора: соперник уже известен, и
-- гонять двоих через matchmaking значило бы, что реванш может свести их с
-- кем-то третьим. Новый матч создаётся здесь же и сразу в 'in_progress' —
-- оба игрока в этот момент стоят на экране итогов и уже согласились.
--
-- РЕЖИМ И ЯЗЫКОВАЯ ПАРА КОПИРУЮТСЯ ИЗ СТАРОГО МАТЧА. Поэтому реванш
-- одинаково работает и в Дуэли, и в Состязании: правила нового боя — это
-- правила того, за который взяли реванш.
create or replace function public.rematch_start(p_match_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_old matches%rowtype;
  v_opponent uuid;
  v_new_id uuid;
begin
  select * into v_old from matches where id = p_match_id;
  if not found or v_uid not in (v_old.player_a_id, v_old.player_b_id) then
    raise exception 'match not found';
  end if;

  v_opponent := case when v_old.player_a_id = v_uid then v_old.player_b_id else v_old.player_a_id end;
  if v_opponent is null then
    raise exception 'no opponent to rematch';
  end if;

  -- Вызов должен быть НЕ свой. Реванш — это ответ на приглашение соперника,
  -- а не способ утащить его в новый бой без спроса.
  if not exists (
    select 1 from match_chat_messages
    where match_id = p_match_id and kind = 'rematch' and user_id = v_opponent
  ) then
    raise exception 'no rematch offer';
  end if;

  -- Уже начали — возвращаем тот же бой. Два нажатия подряд (или оба игрока
  -- сразу) иначе развели бы их по двум разным матчам.
  select new_match_id into v_new_id
  from match_chat_messages
  where match_id = p_match_id and kind = 'rematch_started' and new_match_id is not null
  order by created_at
  limit 1;
  if v_new_id is not null then
    return v_new_id;
  end if;

  insert into matches (player_a_id, player_b_id, game_mode, language_pair, status)
  values (v_old.player_a_id, v_old.player_b_id, v_old.game_mode, v_old.language_pair, 'in_progress')
  returning id into v_new_id;

  insert into match_chat_messages (match_id, user_id, body, kind, new_match_id)
  values (p_match_id, v_uid, 'Реванш принят — бой начинается!', 'rematch_started', v_new_id);

  return v_new_id;
end;
$$;

grant execute on function public.rematch_start(uuid) to authenticated;

-- =========================================================================
-- 5. Realtime
-- =========================================================================
--
-- Без публикации Postgres просто не шлёт события подписчикам, и чат стал бы
-- перепиской, которую видно только после перезахода на экран.
do $$
declare
  t text;
  tables text[] := array['match_chat_messages', 'direct_messages', 'friend_chat_pins'];
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;

  foreach t in array tables loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
