-- =========================================================================
-- Рейтинг: Glicko-2 -> Эло.
--
-- Обратный переход к миграции 0023. Glicko-2 хранил про игрока три числа
-- (рейтинг, отклонение RD, волатильность) и считал лигу по КОНСЕРВАТИВНОЙ
-- оценке rating - 2*RD — то есть показанный игроку рейтинг и рейтинг, по
-- которому ему выдавались лига, сложность фраз и наборы слов, были РАЗНЫМИ
-- числами, и расходились они на 700 очков у новичка. Объяснить это игроку
-- нечем, а с приходом выбора уровня CEFR при регистрации (миграция 0028)
-- стало и невозможно: игрок выбирает «Средний» и должен оказаться на 1500,
-- а не на 1500 с невидимой поправкой на неуверенность системы.
--
-- Эло знает про игрока одно число, и оно же — его лига. Формула:
--   E = 1 / (1 + 10^((R_соперника - R_игрока) / 400))
--   R' = R + K * (S - E),  где S = 1 / 0.5 / 0 (победа / ничья / поражение)
--
-- K (цена одного матча) — по лестнице ФИДЕ, зависящей от опыта и силы:
--   40 — первые 10 матчей (калибровка: новичок должен быстро найти место);
--   20 — дальше;
--   10 — от 2400 (Алмаз): наверху рейтинг должен быть устойчивым.
-- Это заменяет то, ради чего в Glicko-2 было отклонение RD, — «насколько
-- система уверена в игроке» — но одним понятным числом сыгранных матчей
-- вместо скрытой величины.
--
-- Что происходит с существующими игроками. Их новый рейтинг Эло — это их
-- прежний league_rating (rating - 2*RD), а НЕ сырой rating: league_rating
-- это ровно то число, по которому им уже показывалась лига и выдавался
-- контент. Так ни у кого не меняется ни лига, ни уровень фраз — меняется
-- только то, что теперь это же число показано игроку как его рейтинг.
-- Взять сырой rating значило бы поднять всех разом на одну-две лиги.
-- =========================================================================

-- -------------------------------------------------------------------------
-- Счётчик сыгранных матчей: он же мера «насколько система знает игрока»
-- -------------------------------------------------------------------------

-- Растёт в apply_elo_match. Нужен только для выбора K, но нужен обязательно:
-- без него первые матчи новичка стоили бы столько же, сколько сотый матч
-- ветерана, и новичок добирался бы до своей лиги десятками партий.
alter table user_languages
  add column if not exists matches_played integer not null default 0;

comment on column user_languages.matches_played is
  'Сколько рейтинговых матчей сыграно на этой паре. Определяет K: первые '
  '10 матчей идут с K=40 (калибровка), дальше K=20.';

create or replace function public.elo_default_rating()
returns double precision language sql immutable as $$ select 600.0::double precision $$;

comment on function public.elo_default_rating() is
  'Стартовый рейтинг пары, заведённой без выбора уровня CEFR: 600 — '
  'середина Олова, уровень A1. Пары, заведённые через онбординг, '
  'получают рейтинг выбранного уровня (см. set_placement_rating).';

/**
 * Ожидаемый результат игрока с рейтингом p_rating против p_opponent.
 * 0.5 при равных, 0.76 при перевесе в 200 очков, 0.91 при 400.
 */
create or replace function public.elo_expected(
  p_rating double precision,
  p_opponent double precision
) returns double precision
language sql
immutable
as $$
  select 1.0 / (1.0 + power(10.0, (p_opponent - p_rating) / 400.0));
$$;

/**
 * Цена одного матча. Лестница ФИДЕ, см. шапку миграции.
 */
create or replace function public.elo_k(
  p_rating double precision,
  p_matches_played integer
) returns double precision
language sql
immutable
as $$
  select case
    when coalesce(p_matches_played, 0) < 10 then 40.0
    when p_rating >= 2400 then 10.0
    else 20.0
  end;
$$;

-- -------------------------------------------------------------------------
-- Колонки: рейтинг снова одно число
-- -------------------------------------------------------------------------

-- ВАЖЕН ПОРЯДОК: сначала переносим значения (пока rating_deviation ещё
-- существует), и только потом удаляем колонки Glicko-2. Условие переноса —
-- «колонка ещё есть», поэтому повторный прогон миграции ничего не тронет
-- второй раз и не сдвинет рейтинг дважды.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'user_languages'
      and column_name = 'rating_deviation'
  ) then
    -- Новый рейтинг = прежняя консервативная оценка = прежняя лига игрока.
    update user_languages set rating = greatest(0, league_rating);
  end if;
end $$;

-- Триггер из 0023 объявлен как `update of rating, rating_deviation` и потому
-- ЗАВИСИТ от колонки: пока он есть, drop column падает. Снимаем его до
-- удаления колонок и ставим заново (уже без rating_deviation) ниже.
drop trigger if exists trg_sync_rating_mirrors on user_languages;

alter table user_languages
  drop column if exists rating_deviation,
  drop column if exists volatility;

-- rating_updated_at остаётся: в Glicko-2 он был нужен для «старения» RD
-- (давно не игравший становился менее известен системе), в Эло старения
-- нет, но знать дату последнего рейтингового матча полезно и само по себе.
comment on column user_languages.rating_updated_at is
  'Когда последний раз менялся рейтинг. В Эло ни на что не влияет '
  '(старения рейтинга нет), хранится как факт.';

alter table user_languages
  alter column rating set default public.elo_default_rating();

comment on column user_languages.rating is
  'Рейтинг Эло. Источник истины; elo и league_rating — его целочисленные '
  'зеркала, их ведёт триггер trg_sync_rating_mirrors.';
comment on column user_languages.league_rating is
  'Целочисленный рейтинг, по которому считаются лига и сложность фраз. '
  'В Эло РАВЕН rating: отдельной консервативной оценки, как в Glicko-2, '
  'больше нет. Колонка сохранена, потому что на неё ссылаются функции '
  'уровня (cefr_level_for_elo, list_word_packs) и Edge Function судьи.';

-- -------------------------------------------------------------------------
-- Зеркала
-- -------------------------------------------------------------------------

/**
 * league_rating теперь просто округлённый рейтинг: конcервативной оценки
 * rating - 2*RD больше нет, потому что нет и RD. Показанный игроку рейтинг,
 * его лига и уровень выдаваемого контента — одно и то же число.
 */
create or replace function public.sync_rating_mirrors()
returns trigger
language plpgsql
as $$
begin
  -- Отрицательный рейтинг не запрещён формулой Эло, но в игре он не значит
  -- ничего: нижняя лига начинается с 0, и её нижняя граница и есть пол.
  new.rating := greatest(0, new.rating);
  new.elo := round(new.rating)::integer;
  new.league_rating := round(new.rating)::integer;
  new.league := public.league_slug_for_elo(new.league_rating);
  new.cefr_level := public.cefr_level_for_elo(new.league_rating);
  return new;
end;
$$;

-- Триггер больше не должен слушать rating_deviation — колонки нет.
drop trigger if exists trg_sync_rating_mirrors on user_languages;
create trigger trg_sync_rating_mirrors
  before insert or update of rating on user_languages
  for each row execute function public.sync_rating_mirrors();

-- Пересчёт зеркал у всех строк: триггер на UPDATE OF rating срабатывает и
-- тогда, когда значение не изменилось.
update user_languages set rating = rating;

-- -------------------------------------------------------------------------
-- Применение рейтинга к паре игроков
-- -------------------------------------------------------------------------

/**
 * Обновляет рейтинг обоих участников матча по его исходу.
 *
 * p_score_a: 1 — победил A, 0.5 — ничья, 0 — победил B.
 * p_weight: доля, с которой засчитывается ИЗМЕНЕНИЕ рейтинга. 1.0 —
 *   доигранный матч, 0.5 — брошенный (цена выхода вдвое меньше цены
 *   поражения). Счётчик сыгранных матчей растёт в обоих случаях полностью.
 *
 * Возвращает изменения рейтинга (a, b), округлённые до целых, — их
 * показывает экран итогов и хранят matches.elo_change_a/b.
 *
 * Оба игрока считаются от ОДНОГО среза «до матча»: если сначала обновить A,
 * а потом считать B уже от нового рейтинга A, результат зависел бы от
 * порядка и пара получала бы несимметричные изменения.
 */
create or replace function public.apply_elo_match(
  p_user_a uuid,
  p_lang_a text,
  p_user_b uuid,
  p_lang_b text,
  p_score_a double precision,
  p_weight double precision default 1.0
) returns table (change_a integer, change_b integer)
language plpgsql
as $$
declare
  a record;
  b record;
  expected_a double precision;
  delta_a double precision;
  delta_b double precision;
begin
  select rating, matches_played into a
    from user_languages
    where user_id = p_user_a and language_code = p_lang_a and role = 'learning'
    limit 1;
  select rating, matches_played into b
    from user_languages
    where user_id = p_user_b and language_code = p_lang_b and role = 'learning'
    limit 1;

  if a is null or b is null then
    change_a := 0;
    change_b := 0;
    return next;
    return;
  end if;

  expected_a := public.elo_expected(a.rating, b.rating);

  -- K у каждого свой: у новичка против ветерана матч дорог для новичка и
  -- дёшев для ветерана. Сумма изменений при этом не ноль — в Эло с разными
  -- K это нормально и является платой за быструю калибровку новичков.
  delta_a := public.elo_k(a.rating, a.matches_played)
             * (p_score_a - expected_a) * p_weight;
  delta_b := public.elo_k(b.rating, b.matches_played)
             * ((1.0 - p_score_a) - (1.0 - expected_a)) * p_weight;

  update user_languages
    set rating = rating + delta_a,
        matches_played = matches_played + 1,
        rating_updated_at = now()
    where user_id = p_user_a and language_code = p_lang_a and role = 'learning';

  update user_languages
    set rating = rating + delta_b,
        matches_played = matches_played + 1,
        rating_updated_at = now()
    where user_id = p_user_b and language_code = p_lang_b and role = 'learning';

  -- Изменение считаем по факту записи, а не по delta: триггер мог упереть
  -- рейтинг в нижнюю границу 0, и тогда показанное игроку «-18» было бы
  -- враньём.
  select round(rating)::integer - round(a.rating)::integer into change_a
    from user_languages
    where user_id = p_user_a and language_code = p_lang_a and role = 'learning';
  select round(rating)::integer - round(b.rating)::integer into change_b
    from user_languages
    where user_id = p_user_b and language_code = p_lang_b and role = 'learning';
  return next;
end;
$$;

-- -------------------------------------------------------------------------
-- Матч и выход из матча: тела скопированы из 0023, изменён только вызов
-- рейтинговой функции (apply_glicko2_match -> apply_elo_match)
-- -------------------------------------------------------------------------

create or replace function public.finalize_match(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match matches%rowtype;
  v_wins_a integer := 0;
  v_wins_b integer := 0;
  v_total_a integer := 0;
  v_total_b integer := 0;
  v_round_count integer;
  v_scored_rounds integer;
  v_winner uuid;
  v_lang_a text;
  v_lang_b text;
  v_score_a double precision;
  v_change_a integer := 0;
  v_change_b integer := 0;
  v_season uuid;
begin
  select * into v_match from matches where id = p_match_id for update;
  if not found then
    raise exception 'match % not found', p_match_id;
  end if;
  if auth.uid() is distinct from v_match.player_a_id and auth.uid() is distinct from v_match.player_b_id then
    raise exception 'not a participant of this match';
  end if;

  if v_match.status = 'completed' then
    return jsonb_build_object('already_completed', true, 'winner_id', v_match.winner_id);
  end if;
  if v_match.status <> 'in_progress' then
    raise exception 'match % is not in_progress', p_match_id;
  end if;

  select count(*) into v_round_count from rounds where match_id = p_match_id;
  select count(*) into v_scored_rounds
    from rounds r
    where r.match_id = p_match_id
      and exists (select 1 from round_scores s where s.round_id = r.id and s.user_id = v_match.player_a_id and s.score is not null)
      and exists (select 1 from round_scores s where s.round_id = r.id and s.user_id = v_match.player_b_id and s.score is not null);

  if v_round_count < 10 or v_scored_rounds < 10 then
    raise exception 'match % is not fully scored yet (% / 10 rounds scored)', p_match_id, v_scored_rounds;
  end if;

  -- Очки шапки: раунд достаётся тому, кто набрал в нём больше баллов.
  -- Ничейный раунд не даёт очка никому.
  select
    count(*) filter (where sa.score > sb.score),
    count(*) filter (where sb.score > sa.score),
    coalesce(sum(sa.score), 0),
    coalesce(sum(sb.score), 0)
  into v_wins_a, v_wins_b, v_total_a, v_total_b
  from rounds r
  join round_scores sa on sa.round_id = r.id and sa.user_id = v_match.player_a_id
  join round_scores sb on sb.round_id = r.id and sb.user_id = v_match.player_b_id
  where r.match_id = p_match_id;

  if v_wins_a > v_wins_b then
    v_winner := v_match.player_a_id;
  elsif v_wins_b > v_wins_a then
    v_winner := v_match.player_b_id;
  -- Равенство по раундам — решает сумма баллов; равенство и там = ничья.
  elsif v_total_a > v_total_b then
    v_winner := v_match.player_a_id;
  elsif v_total_b > v_total_a then
    v_winner := v_match.player_b_id;
  else
    v_winner := null;
  end if;

  if not v_match.is_bot_opponent then
    if v_match.game_mode = 'native_duel' then
      v_lang_a := split_part(v_match.language_pair, '-', 2);
      v_lang_b := split_part(v_match.language_pair, '-', 1);
    else
      v_lang_a := v_match.language_pair;
      v_lang_b := v_match.language_pair;
    end if;

    -- Счёт матча: 1 — победа A, 0.5 — ничья, 0 — победа B.
    v_score_a := case when v_winner = v_match.player_a_id then 1.0
                      when v_winner is null then 0.5
                      else 0.0 end;
    select change_a, change_b into v_change_a, v_change_b
      from public.apply_elo_match(
        v_match.player_a_id, v_lang_a,
        v_match.player_b_id, v_lang_b,
        v_score_a, 1.0);
  end if;

  update matches set
    status = 'completed',
    winner_id = v_winner,
    elo_change_a = v_change_a,
    elo_change_b = v_change_b,
    completed_at = now()
  where id = p_match_id;

  update currency_wallets set soft_currency = soft_currency + 50 where user_id = v_match.player_a_id;
  update currency_wallets set soft_currency = soft_currency + 50 where user_id = v_match.player_b_id;
  update users set xp = xp + 20 where id = v_match.player_a_id;
  update users set xp = xp + 20 where id = v_match.player_b_id;
  if v_winner is not null then
    update currency_wallets set soft_currency = soft_currency + 50 where user_id = v_winner;
    update users set xp = xp + 30 where id = v_winner;

    -- Очко Победы в Battle Pass (шкала 0-10 за сезон).
    v_season := public.current_season();
    if v_season is not null then
      insert into battle_pass_progress (user_id, season_id, xp, tier, has_premium)
        values (v_winner, v_season, 0, 1, public.has_game_access(v_winner))
      on conflict (user_id, season_id) do update set
        tier = least(10, battle_pass_progress.tier + 1),
        has_premium = public.has_game_access(v_winner);
    end if;
  end if;

  return jsonb_build_object(
    'winner_id', v_winner,
    'round_wins_a', v_wins_a,
    'round_wins_b', v_wins_b,
    'total_a', v_total_a,
    'total_b', v_total_b,
    'elo_change_a', v_change_a,
    'elo_change_b', v_change_b
  );
end;
$$;

-- -------------------------------------------------------------------------
-- Выход из боя: та же половинная цена
-- -------------------------------------------------------------------------

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
  v_score_a double precision;
  v_change_a integer := 0;
  v_change_b integer := 0;
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

    -- Ушедшему засчитывается поражение. Вес 0.5 — цена выхода вдвое
    -- меньше цены честного поражения: изменение рейтинга берётся
    -- наполовину, а счётчик сыгранных матчей растёт полностью — матч
    -- состоялся, и на калибровку K он влияет как обычный.
    v_score_a := case when v_winner = v_match.player_a_id then 1.0 else 0.0 end;
    select change_a, change_b into v_change_a, v_change_b
      from public.apply_elo_match(
        v_match.player_a_id, v_lang_a,
        v_match.player_b_id, v_lang_b,
        v_score_a, 0.5);
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

-- -------------------------------------------------------------------------
-- Уборка Glicko-2
-- -------------------------------------------------------------------------

-- Порядок важен: apply_glicko2_match зовёт glicko2_update, а тот —
-- остальные. Сносим сверху вниз. Ни одна из них больше ниоткуда не
-- вызывается: finalize_match и forfeit_match выше переписаны на
-- apply_elo_match, и это единственные два места, где рейтинг менялся.
drop function if exists public.apply_glicko2_match(uuid, text, uuid, text, double precision, double precision);
drop function if exists public.glicko2_update(
  double precision, double precision, double precision,
  double precision, double precision, double precision, double precision);
drop function if exists public.glicko2_decay(double precision, double precision, double precision);
drop function if exists public.glicko2_volatility(
  double precision, double precision, double precision, double precision);
drop function if exists public.glicko2_f(
  double precision, double precision, double precision, double precision, double precision);
drop function if exists public.glicko2_e(double precision, double precision, double precision);
drop function if exists public.glicko2_g(double precision);
drop function if exists public.glicko2_period_days();
drop function if exists public.glicko2_default_volatility();
drop function if exists public.glicko2_default_rd();
drop function if exists public.glicko2_default_rating();
drop function if exists public.glicko2_tau();
drop function if exists public.glicko2_scale();

-- -------------------------------------------------------------------------
-- Права
-- -------------------------------------------------------------------------

-- apply_elo_match МЕНЯЕТ рейтинг. Postgres по умолчанию раздаёт EXECUTE
-- роли public на каждую новую функцию, то есть без этого отзыва любой
-- авторизованный игрок мог бы вызвать её напрямую и выставить себе любой
-- рейтинг. Её зовут только finalize_match и forfeit_match, а они security
-- definer и проверяют участие в матче.
revoke all on function public.apply_elo_match(uuid, text, uuid, text, double precision, double precision) from public;

-- Чистые функции расчёта читать и вызывать безопасно: они ничего не меняют
-- и ничего не знают о том, чей это рейтинг. Клиент считает по ним «±N» в
-- карточках режимов.
grant execute on function public.elo_expected(double precision, double precision) to authenticated;
grant execute on function public.elo_k(double precision, integer) to authenticated;
grant execute on function public.elo_default_rating() to authenticated;

-- Явно, а не полагаясь на сохранение прав при create or replace.
grant execute on function public.finalize_match(uuid) to authenticated;
grant execute on function public.forfeit_match(uuid) to authenticated;
