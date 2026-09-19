-- =========================================================================
-- ЧЕГО ГОСТЮ НЕЛЬЗЯ — НА СЕРВЕРЕ, А НЕ ТОЛЬКО НА ЭКРАНЕ
-- =========================================================================
--
-- Гостю в приложении открыта одна Арена: остальные вкладки закрыты
-- стеной с предложением зарегистрироваться. НО ЭТО ВСЕГО ЛИШЬ ЭКРАН.
-- Анонимный игрок — обычный `authenticated`, и все RPC и таблицы у него
-- те же; обойти стену значит послать запрос мимо приложения.
--
-- Документация Supabase предупреждает об этом прямо: «Review your
-- existing RLS policies before enabling anonymous sign-ins. Anonymous
-- users use the `authenticated` role.»
--
-- ЧТО ИМЕННО ЗАКРЫВАЕМ. Только то, что видят ДРУГИЕ люди: переписку в
-- матче, личные сообщения и заявки в друзья. Спам от одноразового
-- аккаунта — единственная настоящая беда, которую гость может устроить
-- не себе, а чужому человеку.
--
-- ЧТО НЕ ЗАКРЫВАЕМ. Всё, что гость делает сам с собой: бои, записи,
-- монеты, серию, покупки. Испортить он этим может только собственный
-- аккаунт, а ограничение сделало бы Арену неиграбельной — то есть
-- отняло бы ровно то, ради чего гостя и пускают.
--
-- ПОЧЕМУ RESTRICTIVE. Обычные политики складываются через ИЛИ: добавить
-- к ним ещё одну разрешающую бесполезно. Ограничивающая складывается
-- через И — то есть запрещает поверх всего, что разрешено.

-- Переписка в матче.
drop policy if exists match_chat_insert_not_guest on public.match_chat_messages;
create policy match_chat_insert_not_guest on public.match_chat_messages
  as restrictive for insert to authenticated
  with check ((select (auth.jwt() ->> 'is_anonymous')::boolean) is not true);

-- Личные сообщения.
drop policy if exists direct_messages_insert_not_guest on public.direct_messages;
create policy direct_messages_insert_not_guest on public.direct_messages
  as restrictive for insert to authenticated
  with check ((select (auth.jwt() ->> 'is_anonymous')::boolean) is not true);

-- Заявки в друзья: и создать, и принять.
drop policy if exists friendships_insert_not_guest on public.friendships;
create policy friendships_insert_not_guest on public.friendships
  as restrictive for insert to authenticated
  with check ((select (auth.jwt() ->> 'is_anonymous')::boolean) is not true);

drop policy if exists friendships_update_not_guest on public.friendships;
create policy friendships_update_not_guest on public.friendships
  as restrictive for update to authenticated
  using ((select (auth.jwt() ->> 'is_anonymous')::boolean) is not true);

-- `is not true`, а не `is false`, НАРОЧНО: у старых токенов, выписанных
-- до включения анонимного входа, claim'а нет вовсе, и `is false` дало бы
-- NULL — то есть отказ живому игроку. `is not true` пропускает и тех, и
-- других, а останавливает ровно анонимных.
