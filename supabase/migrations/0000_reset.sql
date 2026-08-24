-- Чистый откат схемы Language Battle. Нужен только если 0001/0002
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

-- Если удаление бакета упадёт из-за уже загруженных файлов — не страшно,
-- пропустите эту строку и продолжайте: 0002 создаёт бакет через
-- "on conflict do nothing", повторное наличие бакета не мешает.
delete from storage.buckets where id = 'voice-recordings';
