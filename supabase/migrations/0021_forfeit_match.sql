-- Выход из боя завершает бой.
--
-- Раньше выход просто сворачивал экран: матч оставался в 'in_progress', и
-- соперник ждал ответа, которого уже не будет, пока auto_skip_stale_rounds
-- не спишет ему раунд за раундом. Список «Активные бои» существовал ровно
-- ради возврата в такие подвешенные матчи, и вместе с этой правкой уходит.
--
-- Цена выхода — половина: ушедший теряет вдвое меньше рейтинга, чем при
-- настоящем поражении, а оставшийся получает вдвое меньше, чем за
-- настоящую победу. Так выход остаётся невыгодным, но не превращается в
-- наказание, несоразмерное недоигранному бою.
--
-- Монеты, XP и очко Battle Pass за такой матч НЕ начисляются никому:
-- иначе сдача превратилась бы в самый быстрый способ их фармить.

alter table matches
  add column if not exists forfeited_by uuid references users(id);

comment on column matches.forfeited_by is
  'Кто вышел из боя досрочно. NULL — бой доигран до конца.';

create or replace function public.forfeit_match(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match matches%rowtype;
  v_leaver uuid;
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
begin
  select * into v_match from matches where id = p_match_id for update;
  if not found then
    raise exception 'match % not found', p_match_id;
  end if;

  v_leaver := auth.uid();
  if v_leaver is distinct from v_match.player_a_id and v_leaver is distinct from v_match.player_b_id then
    raise exception 'not a participant of this match';
  end if;

  -- Повторный выход (второй телефон, потерянная сеть, двойное нажатие) —
  -- не ошибка: просто возвращаем уже принятое решение.
  if v_match.status = 'completed' then
    return jsonb_build_object(
      'already_completed', true,
      'winner_id', v_match.winner_id,
      'forfeited_by', v_match.forfeited_by
    );
  end if;
  if v_match.status <> 'in_progress' then
    raise exception 'match % is not in_progress', p_match_id;
  end if;

  v_winner := case when v_leaver = v_match.player_a_id
                   then v_match.player_b_id
                   else v_match.player_a_id end;

  if not v_match.is_bot_opponent and v_winner is not null then
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
        where status = 'completed' and not is_bot_opponent
          and (player_a_id = v_match.player_a_id or player_b_id = v_match.player_a_id);
      select count(*) into v_matches_b from matches
        where status = 'completed' and not is_bot_opponent
          and (player_a_id = v_match.player_b_id or player_b_id = v_match.player_b_id);
      v_k_a := case when v_matches_a < 30 then 32 else 16 end;
      v_k_b := case when v_matches_b < 30 then 32 else 16 end;

      v_expected_a := 1.0 / (1.0 + power(10.0, (v_elo_b - v_elo_a) / 400.0));
      v_actual_a := case when v_winner = v_match.player_a_id then 1.0 else 0.0 end;

      -- Тот же расчёт, что и в finalize_match, но ровно вполовину: цена
      -- недоигранного боя не должна равняться цене доигранного.
      v_change_a := round(v_k_a * (v_actual_a - v_expected_a) / 2.0);
      v_change_b := round(v_k_b * ((1.0 - v_actual_a) - (1.0 - v_expected_a)) / 2.0);

      update user_languages set elo = elo + v_change_a
        where user_id = v_match.player_a_id and language_code = v_lang_a and role = 'learning';
      update user_languages set elo = elo + v_change_b
        where user_id = v_match.player_b_id and language_code = v_lang_b and role = 'learning';
    end if;
  end if;

  update matches set
    status = 'completed',
    winner_id = v_winner,
    forfeited_by = v_leaver,
    elo_change_a = v_change_a,
    elo_change_b = v_change_b,
    completed_at = now()
  where id = p_match_id;

  return jsonb_build_object(
    'winner_id', v_winner,
    'forfeited_by', v_leaver,
    'elo_change_a', v_change_a,
    'elo_change_b', v_change_b
  );
end;
$$;

grant execute on function public.forfeit_match(uuid) to authenticated;
