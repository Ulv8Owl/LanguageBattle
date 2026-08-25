-- Chrolingo — таймаут раунда с автосписанием, возврат соперника в очередь
-- при отказе, удаление аудио сразу после боя, и хранение индекса фразы
-- для честного банка без повторов внутри матча. Реализует пункты 5, 6 и 7
-- из deferred_suggestions.md — они были там временными записями и
-- переносятся в основную реализацию по отдельному запросу владельца
-- проекта.

-- =========================================================================
-- 1. Индекс фразы (см. lib/data/phrase_bank.dart) — клиент подставляет
--    фразы из фиксированного присланного списка, а не генерирует их через
--    LLM. Индекс нужен только PvP-раундам: клиенты гонятся за созданием
--    следующего раунда, и без общего источника правды о том, какие фразы
--    уже звучали в этом матче, не получится честно исключать повторы.
--    Одиночная Игра не гонится ни с кем — там порядок фраз перемешивается
--    один раз локально на клиенте, серверный индекс ей не нужен.
-- =========================================================================

alter table rounds add column if not exists phrase_index integer;

-- =========================================================================
-- 2. Таймаут раунда: если игрок не начал отвечать (не прислал ни одного
--    голосового на изучаемом языке) за p_timeout_seconds секунд — ему
--    засчитывается минимальный балл, чтобы брошенный партнёром матч не
--    зависал в 'in_progress' навсегда. Это НЕ ограничение на длину самой
--    записи (см. раздел 7 спеки) — только на время "раскачки" перед ней.
--
--    Вызывается двумя путями:
--    - клиентом каждые несколько секунд, пока матч идёт (see
--      battle_screen.dart) — даёт точный таймаут, пока хотя бы один из
--      игроков не закрыл приложение;
--    - опционально из pg_cron, если расширение доступно на проекте — это
--      подстраховка на случай, когда ОБА клиента свёрнуты/закрыты
--      (минимальная гранулярность pg_cron — минута, поэтому это только
--      подстраховка, не основной механизм точного таймаута).
-- =========================================================================

create or replace function public.auto_skip_stale_rounds(p_timeout_seconds integer default 40)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  v_skipped integer := 0;
begin
  for v_round in
    select r.id as round_id, m.player_a_id, m.player_b_id
    from rounds r
    join matches m on m.id = r.match_id
    where m.status = 'in_progress'
      and r.created_at < now() - make_interval(secs => p_timeout_seconds)
      and r.round_number = (
        select max(r2.round_number) from rounds r2 where r2.match_id = r.match_id
      )
  loop
    if v_round.player_a_id is not null
       and not exists (
         select 1 from voice_recordings
         where round_id = v_round.round_id
           and user_id = v_round.player_a_id
           and recording_slot = 'target'
       )
    then
      insert into round_scores (round_id, user_id, score, ai_feedback)
        values (v_round.round_id, v_round.player_a_id, 1, 'Раунд пропущен — истекло время ожидания голосового.')
      on conflict (round_id, user_id) do nothing;
      if found then v_skipped := v_skipped + 1; end if;
    end if;

    if v_round.player_b_id is not null
       and not exists (
         select 1 from voice_recordings
         where round_id = v_round.round_id
           and user_id = v_round.player_b_id
           and recording_slot = 'target'
       )
    then
      insert into round_scores (round_id, user_id, score, ai_feedback)
        values (v_round.round_id, v_round.player_b_id, 1, 'Раунд пропущен — истекло время ожидания голосового.')
      on conflict (round_id, user_id) do nothing;
      if found then v_skipped := v_skipped + 1; end if;
    end if;
  end loop;

  return v_skipped;
end;
$$;

grant execute on function public.auto_skip_stale_rounds(integer) to authenticated;

-- Необязательная подстраховка через pg_cron. Обёрнута в DO-блоки с
-- перехватом исключений: на части Supabase-проектов расширение выключено
-- или недоступно тарифом — миграция не должна падать целиком из-за этого,
-- клиентский путь (вызов из battle_screen.dart) работает независимо.
do $$
begin
  execute 'create extension if not exists pg_cron with schema extensions';
exception when others then
  raise notice 'pg_cron недоступен — фоновая подстраховка пропущена, клиентский вызов auto_skip_stale_rounds всё равно работает: %', sqlerrm;
end $$;

do $$
begin
  perform cron.unschedule('chrolingo_auto_skip_stale_rounds');
exception when others then
  null; -- задачи ещё не было — нормально
end $$;

do $$
begin
  perform cron.schedule(
    'chrolingo_auto_skip_stale_rounds',
    '* * * * *',
    $sql$select public.auto_skip_stale_rounds();$sql$
  );
exception when others then
  raise notice 'не удалось запланировать pg_cron задачу (расширение вероятно недоступно): %', sqlerrm;
end $$;

-- =========================================================================
-- 3. Возврат соперника в очередь при отказе/неподтверждении найденного
--    матча — вместо того чтобы отменять поиск и второй стороне тоже.
-- =========================================================================

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

    -- Встречная сторона не виновата, что мы отказались/не успели
    -- подтвердить — возвращаем её в поиск со свежим окном вместо отмены
    -- (раздел 2.3). Клиент опознаёт это по своему же тикету через
    -- Realtime и перезапускает локальный цикл поиска (см.
    -- matchmaking_screen.dart).
    update matchmaking_tickets set
      status = 'searching',
      match_id = null,
      opponent_ticket_id = null,
      accepted = false,
      expires_at = now() + interval '35 seconds'
      where id = v_me.opponent_ticket_id and status in ('found', 'accepted');
  end if;
end;
$$;

grant execute on function public.mm_cancel(uuid) to authenticated;

-- =========================================================================
-- 4. Аудио не хранится вообще: сразу после завершения матча/раунда
--    (обоих режимов) записи удаляются клиентом из Storage. Клиенту нужна
--    DELETE-политика на storage.objects — раньше её не было (только
--    SELECT/INSERT из 0002), поэтому "удалить своё" было физически
--    невозможно.
-- =========================================================================

create policy "voice-recordings: participants can delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'voice-recordings'
    and (
      (
        (storage.foldername(name))[1] = 'match'
        and exists (
          select 1 from matches m
          where m.id::text = (storage.foldername(name))[2]
            and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
        )
      )
      or (
        (storage.foldername(name))[1] = 'training'
        and exists (
          select 1 from training_sessions ts
          where ts.id::text = (storage.foldername(name))[2]
            and ts.user_id = auth.uid()
        )
      )
    )
  );

-- =========================================================================
-- 5. Гранты для новых объектов этой миграции.
-- =========================================================================

grant select, insert, update, delete on all tables in schema public to authenticated;
