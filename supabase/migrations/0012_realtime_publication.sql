-- Клиент узнаёт о результатах через Realtime (.stream() в Flutter) на
-- нескольких таблицах: evaluation_jobs, training_rounds, voice_recordings,
-- round_scores, matches, rounds, matchmaking_tickets, party_invites. Ни одна
-- миграция раньше не добавляла эти таблицы в публикацию supabase_realtime —
-- без этого Postgres просто не шлёт события подписчикам, даже если сама
-- строка в БД давно обновилась. Это, судя по всему, и есть причина
-- "зависает на Разбираю первую попытку": сам job у evaluate-recording
-- отрабатывал (status=done за доли секунды), но клиент никогда не получал
-- об этом уведомление, так как таблица evaluation_jobs не транслировалась.
--
-- Идемпотентно (через pg_publication_tables) — безопасно повторно
-- применить поверх таблиц, которые уже могли быть включены вручную через
-- Dashboard → Database → Replication.

do $$
declare
  t text;
  tables text[] := array[
    'evaluation_jobs',
    'training_rounds',
    'voice_recordings',
    'round_scores',
    'matches',
    'rounds',
    'matchmaking_tickets',
    'party_invites'
  ];
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
