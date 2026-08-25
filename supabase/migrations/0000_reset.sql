-- Чистый откат схемы Chrolingo. Нужен только если 0001/0002
-- выполнились частично (например, упали на середине) и повторный прогон
-- ругается на "relation ... already exists". Прогоните этот файл один раз,
-- затем заново 0001_initial_schema.sql и 0002_rls_and_storage.sql.
--
-- Безопасно, если в базе ещё нет реальных данных — удаляет все таблицы
-- проекта целиком (CASCADE), включая все их RLS-политики.

drop table if exists
  reports,
  friendships,
  battle_pass_progress,
  battle_pass_seasons,
  user_inventory,
  cosmetic_items,
  currency_wallets,
  matchmaking_tickets,
  evaluation_jobs,
  round_scores,
  grammar_errors,
  voice_recordings,
  training_rounds,
  training_sessions,
  rounds,
  matches,
  user_languages,
  users
cascade;

-- CASCADE здесь также удаляет триггер on_auth_user_created на auth.users,
-- поскольку он зависит от этой функции.
drop function if exists public.handle_new_auth_user() cascade;

drop policy if exists "voice-recordings: participants can read" on storage.objects;
drop policy if exists "voice-recordings: participants can upload" on storage.objects;

-- Бакет voice-recordings нарочно не трогаем: Supabase запрещает удалять
-- строки storage.buckets/storage.objects напрямую через SQL ("Direct
-- deletion from storage tables is not allowed"). Это не мешает — 0002
-- создаёт бакет через "on conflict do nothing", так что повторное его
-- наличие безвредно. Если когда-нибудь понадобится удалить сам бакет —
-- это делается через Storage UI/API, не через SQL Editor.
