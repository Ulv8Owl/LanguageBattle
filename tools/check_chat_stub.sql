-- Заглушки для проверки миграции 0049 на пустом Postgres.
--
-- ТОЛЬКО ТО, НА ЧТО ССЫЛАЕТСЯ МИГРАЦИЯ: три таблицы, роль authenticated и
-- auth.uid(), который в Supabase отдаёт текущего пользователя, а здесь —
-- значение из настройки test.uid. Копировать сюда всю схему приложения
-- незачем: проверяются правила доступа к чатам, а не она.

create extension if not exists pgcrypto;
create role authenticated;
create role app_user login;
grant authenticated to app_user;

create schema if not exists auth;
create or replace function auth.uid() returns uuid
language sql stable
as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create table users (
  id uuid primary key default gen_random_uuid(),
  username text
);

create table matches (
  id uuid primary key default gen_random_uuid(),
  player_a_id uuid references users(id),
  player_b_id uuid references users(id),
  game_mode text not null check (game_mode in ('sparring','native_duel')),
  language_pair text,
  is_bot_opponent boolean not null default false,
  status text not null check (status in ('matchmaking','in_progress','completed','abandoned')),
  winner_id uuid references users(id),
  created_at timestamptz not null default now()
);

create table friendships (
  user_id uuid references users(id) on delete cascade,
  friend_id uuid references users(id) on delete cascade,
  status text check (status in ('pending','accepted','blocked')),
  primary key (user_id, friend_id)
);

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
