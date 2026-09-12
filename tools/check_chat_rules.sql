\set ON_ERROR_STOP on
-- Правила доступа к чатам и реваншу — проверка на настоящем Postgres.
--
-- ЗАЧЕМ ОНА ЕСТЬ. Политика RLS, которую никто не пробовал нарушить, — это
-- не защита, а намерение. Здесь за каждого из троих (двое в матче и
-- посторонний) делается ровно то, что делать нельзя, и проверяется, что
-- база отказала.
--
-- КАК ЗАПУСТИТЬ (нужен любой пустой Postgres; схема приложения целиком не
-- требуется — заглушки ниже создают только то, на что ссылается миграция):
--
--   psql -f tools/check_chat_stub.sql
--   psql -f supabase/migrations/0049_chats_and_rematch.sql
--   psql -f tools/check_chat_rules.sql
--
-- Всё сошлось, если в выводе нет ни одного слова ПРОВАЛ.

-- Двое игроков, доигранный матч и дружба между ними.
insert into users (id, username) values
  ('11111111-1111-1111-1111-111111111111','Аня'),
  ('22222222-2222-2222-2222-222222222222','Боря'),
  ('33333333-3333-3333-3333-333333333333','Посторонний');
insert into matches (id, player_a_id, player_b_id, game_mode, language_pair, status)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        'native_duel','ru-en','completed');
insert into friendships values
  ('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222','accepted');

set role app_user;

-- Аня пишет в чат своего матча.
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
insert into match_chat_messages (match_id, user_id, body)
values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Хорошо сыграл!');
select 'своё сообщение в своём матче: ok' as t;

-- Посторонний в этот чат не пишет и его не видит.
select set_config('test.uid', '33333333-3333-3333-3333-333333333333', false);
select 'посторонний видит сообщений: ' || count(*)::text from match_chat_messages;
do $$
begin
  insert into match_chat_messages (match_id, user_id, body)
  values ('aaaaaaaa-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','подслушиваю');
  raise exception 'ПРОВАЛ: посторонний написал в чужой чат';
exception when insufficient_privilege then
  raise notice 'посторонний в чужой чат не пишет: ok';
end $$;

-- От чужого имени в своём матче тоже нельзя.
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
do $$
begin
  insert into match_chat_messages (match_id, user_id, body)
  values ('aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','это не я');
  raise exception 'ПРОВАЛ: написал от лица соперника';
exception when insufficient_privilege then
  raise notice 'от лица соперника не пишем: ok';
end $$;

-- 'rematch_started' клиенту недоступен.
do $$
begin
  insert into match_chat_messages (match_id, user_id, body, kind)
  values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','бой','rematch_started');
  raise exception 'ПРОВАЛ: клиент подделал сообщение о начатом бое';
exception when insufficient_privilege then
  raise notice 'служебное сообщение клиенту недоступно: ok';
end $$;

-- Реванш без вызова соперника не начинается.
do $$
begin
  perform rematch_start('aaaaaaaa-0000-0000-0000-000000000001');
  raise exception 'ПРОВАЛ: реванш начался без вызова';
exception when others then
  if sqlerrm <> 'no rematch offer' then raise; end if;
  raise notice 'без вызова реванша нет: ok';
end $$;

-- Боря зовёт, Аня принимает.
select set_config('test.uid', '22222222-2222-2222-2222-222222222222', false);
insert into match_chat_messages (match_id, user_id, body, kind)
values ('aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','Реванш!','rematch');

select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select 'новый бой: ' || rematch_start('aaaaaaaa-0000-0000-0000-000000000001')::text as t;
-- Второе нажатие ведёт в ТОТ ЖЕ бой.
select 'повторный вызов даёт тот же бой: ' ||
  (select count(distinct id) = 1 from matches where status = 'in_progress')::text as t
from (select rematch_start('aaaaaaaa-0000-0000-0000-000000000001')) s;
select 'режим и пара скопированы: ' || (game_mode = 'native_duel' and language_pair = 'ru-en')::text as t
from matches where status = 'in_progress';

-- Личные сообщения: другу можно, чужому нельзя.
insert into direct_messages (sender_id, recipient_id, body)
values ('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222','привет');
select 'другу пишем: ok' as t;
do $$
begin
  insert into direct_messages (sender_id, recipient_id, body)
  values ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','эй');
  raise exception 'ПРОВАЛ: написал не другу';
exception when insufficient_privilege then
  raise notice 'не другу писать нельзя: ok';
end $$;

-- Переписку видят только двое.
select set_config('test.uid', '33333333-3333-3333-3333-333333333333', false);
select 'посторонний видит личных сообщений: ' || count(*)::text from direct_messages;
select set_config('test.uid', '22222222-2222-2222-2222-222222222222', false);
select 'получатель видит личных сообщений: ' || count(*)::text from direct_messages;

-- Закрепления свои у каждого.
insert into friend_chat_pins (user_id, friend_id)
values ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111');
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select 'чужое закрепление у меня не видно: ' || count(*)::text from friend_chat_pins;
