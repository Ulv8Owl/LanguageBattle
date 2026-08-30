-- Время на ответ в раунде: 40 секунд -> 120.
--
-- Пока оба игрока в PvP — это один человек с двумя телефонами (записать надо
-- в оба по очереди), сорока секунд не хватает физически: раунд списывался
-- штрафом раньше, чем удавалось ответить.
--
-- Меняется ТОЛЬКО значение по умолчанию, тело функции скопировано из
-- миграции 0007 без правок. Клиент всё равно передаёт p_timeout_seconds
-- явно (battle_screen.dart, _roundTimeoutSeconds), чтобы отсчёт на экране и
-- списание на сервере не могли разойтись молча; умолчание нужно для вызовов
-- без параметра.

create or replace function public.auto_skip_stale_rounds(p_timeout_seconds integer default 120)
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

-- Сигнатура не изменилась (менялось только умолчание), так что права
-- сохраняются — повторяем на случай, если функция создаётся с нуля.
grant execute on function public.auto_skip_stale_rounds(integer) to authenticated;
