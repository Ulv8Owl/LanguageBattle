-- =========================================================================
-- Рейтинг: Эло -> Glicko-2 (Mark E. Glickman).
--
-- Зачем. Эло знает про игрока одно число и одинаково доверяет и новичку с
-- тремя матчами, и ветерану с тремя сотнями: коэффициент K задаётся вручную
-- и к реальной неопределённости отношения не имеет. Glicko-2 хранит ещё две
-- величины — отклонение (насколько система уверена в рейтинге) и
-- волатильность (насколько игрок нестабилен) — и сам решает, сильно ли
-- двигать рейтинг после матча. Новичок находит своё место за несколько
-- партий, устоявшийся игрок не прыгает от одного поражения, а давно не
-- игравший автоматически становится «менее известен» системе.
--
-- Шкала. mu = (r - 1500)/173.7178, phi = RD/173.7178, где 173.7178 =
-- 400/ln(10). Стартовые значения по Гликману: рейтинг 1500, отклонение 350,
-- волатильность 0.06, константа системы tau = 0.5.
--
-- Период рейтинга. Glicko-2 описан для периода из НЕСКОЛЬКИХ партий, но
-- здесь матч — редкое событие, и результат игрок должен увидеть сразу на
-- экране итогов. Поэтому период = один матч. Гликман это допускает, отмечая
-- меньшую точность оценки волатильности; альтернатива — показывать новый
-- рейтинг через неделю, что для игры неприемлемо. За простой между матчами
-- отклонение растёт (шаг 6), период простоя — неделя.
--
-- Проверка. Функции сверены с независимой реализацией на 400 случайных
-- входах (совпадение до последнего разряда double) и с опубликованным
-- примером Гликмана: v = 1.7790, Delta = -0.4839, sigma' = 0.059996,
-- phi* = 1.1529, phi' = 0.8722. В самой статье напечатаны 1.7785 и -0.4834 —
-- это результат подстановки округлённых до трёх знаков промежуточных E
-- обратно в формулу; точный расчёт даёт значения выше.
-- =========================================================================

-- -------------------------------------------------------------------------
-- Константы и элементарные функции
-- -------------------------------------------------------------------------

create or replace function public.glicko2_scale()
returns double precision language sql immutable as $$ select 173.7178::double precision $$;

-- tau ограничивает, насколько волатильность может измениться за период.
-- Гликман рекомендует 0.3..1.2; 0.5 — общепринятое. Меньше — рейтинг
-- спокойнее, больше — быстрее реагирует на реально изменившуюся силу.
create or replace function public.glicko2_tau()
returns double precision language sql immutable as $$ select 0.5::double precision $$;

-- Стартовые значения новичка.
create or replace function public.glicko2_default_rating()
returns double precision language sql immutable as $$ select 1500.0::double precision $$;

create or replace function public.glicko2_default_rd()
returns double precision language sql immutable as $$ select 350.0::double precision $$;

create or replace function public.glicko2_default_volatility()
returns double precision language sql immutable as $$ select 0.06::double precision $$;

-- Сколько дней составляет один период рейтинга — на столько «стареет»
-- уверенность в рейтинге у не играющего.
create or replace function public.glicko2_period_days()
returns double precision language sql immutable as $$ select 7.0::double precision $$;

-- g(phi): вес соперника. Чем менее уверен рейтинг соперника, тем меньше
-- значит результат встречи с ним.
create or replace function public.glicko2_g(p_phi double precision)
returns double precision language sql immutable as $$
  select 1.0 / sqrt(1.0 + 3.0 * p_phi * p_phi / (pi() * pi()));
$$;

-- E: ожидаемый результат против соперника.
create or replace function public.glicko2_e(
  p_mu double precision, p_mu_j double precision, p_phi_j double precision
) returns double precision language sql immutable as $$
  select 1.0 / (1.0 + exp(-public.glicko2_g(p_phi_j) * (p_mu - p_mu_j)));
$$;

/**
 * f(x) из шага 5.
 *
 * f(x) = e^x (D^2 - phi^2 - v - e^x) / (2(phi^2 + v + e^x)^2) - (x - a)/tau^2
 *
 * ВНИМАНИЕ: здесь именно phi^2 — отклонение, а НЕ mu^2. Распространённая
 * python-библиотека glicko2 подставляет туда mu^2, и на опубликованном
 * примере Гликмана расхождения не даёт: там волатильность почти не меняется
 * и ошибка маскируется. Вылезает она на сериях неожиданных исходов — то
 * есть ровно там, ради чего волатильность и вводилась.
 */
create or replace function public.glicko2_f(
  p_x double precision,
  p_phi double precision,
  p_v double precision,
  p_delta double precision,
  p_a double precision
) returns double precision language sql immutable as $$
  select
    (exp(p_x) * (p_delta * p_delta - p_phi * p_phi - p_v - exp(p_x)))
      / (2.0 * power(p_phi * p_phi + p_v + exp(p_x), 2))
    - (p_x - p_a) / (public.glicko2_tau() * public.glicko2_tau());
$$;

/**
 * Шаг 5: новая волатильность. Уравнение f(x)=0 решается методом Иллинойса —
 * Ньютон здесь неустойчив, а простое деление пополам сходится слишком долго.
 */
create or replace function public.glicko2_volatility(
  p_phi double precision,
  p_v double precision,
  p_delta double precision,
  p_sigma double precision
) returns double precision
language plpgsql immutable as $$
declare
  v_tau constant double precision := public.glicko2_tau();
  v_eps constant double precision := 0.000001;
  a double precision := ln(p_sigma * p_sigma);
  aa double precision;
  bb double precision;
  cc double precision;
  f_a double precision;
  f_b double precision;
  f_c double precision;
  k integer := 1;
  guard integer := 0;
begin
  aa := a;

  if p_delta * p_delta > p_phi * p_phi + p_v then
    bb := ln(p_delta * p_delta - p_phi * p_phi - p_v);
  else
    loop
      exit when public.glicko2_f(a - k * v_tau, p_phi, p_v, p_delta, a) >= 0;
      k := k + 1;
      exit when k > 1000;  -- страховка: цикл не должен стать бесконечным
    end loop;
    bb := a - k * v_tau;
  end if;

  f_a := public.glicko2_f(aa, p_phi, p_v, p_delta, a);
  f_b := public.glicko2_f(bb, p_phi, p_v, p_delta, a);

  while abs(bb - aa) > v_eps and guard < 200 loop
    guard := guard + 1;
    cc := aa + (aa - bb) * f_a / (f_b - f_a);
    f_c := public.glicko2_f(cc, p_phi, p_v, p_delta, a);
    if f_c * f_b <= 0 then
      aa := bb;
      f_a := f_b;
    else
      f_a := f_a / 2.0;
    end if;
    bb := cc;
    f_b := f_c;
  end loop;

  return exp(aa / 2.0);
end;
$$;

/**
 * Шаг 6 отдельно: рост отклонения за время простоя. Рейтинг не меняется.
 *
 * Потолок 350 — отклонение новичка: ниже этой уверенности опускаться
 * некуда, иначе давно не игравший стал бы для системы «неизвестнее
 * новичка», а матчмейкинг подбирал бы ему кого угодно.
 */
create or replace function public.glicko2_decay(
  p_rd double precision,
  p_sigma double precision,
  p_elapsed_periods double precision
) returns double precision language sql immutable as $$
  select least(
    public.glicko2_default_rd(),
    sqrt(p_rd * p_rd
         + p_sigma * p_sigma * public.glicko2_scale() * public.glicko2_scale()
           * greatest(0.0, p_elapsed_periods))
  );
$$;

/**
 * Полное обновление по итогам периода из одной встречи.
 *
 * p_score: 1 — победа, 0.5 — ничья, 0 — поражение.
 * p_elapsed_periods: сколько периодов простоя прошло до матча.
 */
create or replace function public.glicko2_update(
  p_rating double precision,
  p_rd double precision,
  p_sigma double precision,
  p_opp_rating double precision,
  p_opp_rd double precision,
  p_score double precision,
  p_elapsed_periods double precision default 0
) returns table (rating double precision, rating_deviation double precision, volatility double precision)
language plpgsql immutable as $$
declare
  s constant double precision := public.glicko2_scale();
  mu double precision;
  phi double precision;
  mu_j double precision;
  phi_j double precision;
  gj double precision;
  ej double precision;
  v double precision;
  delta double precision;
  delta_sum double precision;
  sigma_new double precision;
  phi_star double precision;
  phi_new double precision;
  mu_new double precision;
  rd_inflated double precision;
begin
  rd_inflated := public.glicko2_decay(p_rd, p_sigma, p_elapsed_periods);

  mu := (p_rating - 1500.0) / s;
  phi := rd_inflated / s;
  mu_j := (p_opp_rating - 1500.0) / s;
  phi_j := p_opp_rd / s;

  gj := public.glicko2_g(phi_j);
  ej := public.glicko2_e(mu, mu_j, phi_j);

  v := 1.0 / (gj * gj * ej * (1.0 - ej));
  delta_sum := gj * (p_score - ej);
  delta := v * delta_sum;

  sigma_new := public.glicko2_volatility(phi, v, delta, p_sigma);

  phi_star := sqrt(phi * phi + sigma_new * sigma_new);
  phi_new := 1.0 / sqrt(1.0 / (phi_star * phi_star) + 1.0 / v);
  mu_new := mu + phi_new * phi_new * delta_sum;

  rating := 1500.0 + s * mu_new;
  rating_deviation := s * phi_new;
  volatility := sigma_new;
  return next;
end;
$$;

-- -------------------------------------------------------------------------
-- Хранение рейтинга
-- -------------------------------------------------------------------------

-- Столбцы добавляются БЕЗ умолчаний и nullable, заполняются, и только
-- потом получают not null и умолчание. Иначе перенос данных пришлось бы
-- отличать «по значению» — а повторный прогон миграции тогда пересчитал бы
-- рейтинг ещё раз и раздул его вдвое. Так условие переноса — «столбец ещё
-- пуст», и второй раз оно просто не выполняется.
alter table user_languages
  add column if not exists rating double precision,
  add column if not exists rating_deviation double precision,
  add column if not exists volatility double precision,
  add column if not exists rating_updated_at timestamptz,
  add column if not exists league_rating integer;

comment on column user_languages.rating is
  'Рейтинг Glicko-2. Источник истины; elo — его целочисленное зеркало.';
comment on column user_languages.rating_deviation is
  'Отклонение (RD): насколько система уверена в рейтинге. 350 — новичок.';
comment on column user_languages.volatility is
  'Волатильность (sigma): насколько нестабильны результаты игрока.';
comment on column user_languages.league_rating is
  'Консервативная оценка силы, rating - 2*RD. По ней считается лига и '
  'сложность фраз: пока система в игроке не уверена, она не выдаёт ему '
  'материал верхних уровней.';
comment on column user_languages.elo is
  'УСТАРЕЛО как самостоятельная величина: целочисленное зеркало rating, '
  'нужное матчмейкингу (matchmaking_tickets.elo, mm_search) и старым '
  'запросам. Не изменять напрямую — его ставит триггер.';

-- Перенос существующих строк. Эло и Glicko-2 — разные шкалы, поэтому
-- сохраняем не абсолютное число, а взаимное положение игроков: старый
-- старт 1000 соответствует новому старту 1500, то есть rating = elo + 500.
--
-- Отклонение при переносе — 250, а не начальные 350. Число выбрано не на
-- глаз: лига считается по rating - 2*RD, и при RD = 250 это ровно
-- (elo + 500) - 500 = elo. То есть в день миграции консервативная оценка
-- каждого игрока совпадает с его прежним эло и никто не меняет лигу —
-- обновление не отбирает уже заработанное. По смыслу 250 тоже честно:
-- партии эти люди играли, но истории в терминах Glicko-2 у нас нет,
-- поэтому уверенность высокая, но не полная. Новые строки заводятся уже с
-- настоящим начальным 350 (default ниже).
update user_languages
set rating = 1500.0 + (coalesce(elo, 1000) - 1000),
    rating_deviation = 250,
    volatility = public.glicko2_default_volatility(),
    rating_updated_at = now()
where rating is null;

alter table user_languages
  alter column rating set default 1500,
  alter column rating_deviation set default 350,
  alter column volatility set default 0.06,
  alter column rating_updated_at set default now();

alter table user_languages
  alter column rating set not null,
  alter column rating_deviation set not null,
  alter column volatility set not null,
  alter column rating_updated_at set not null;

-- -------------------------------------------------------------------------
-- Лига и уровень CEFR
-- -------------------------------------------------------------------------

/**
 * Лига считается по КОНСЕРВАТИВНОЙ оценке rating - 2*RD, а не по самому
 * рейтингу. Это стандартный для Glicko способ ответить на вопрос «насколько
 * игрок силён наверняка», и здесь он важен вдвойне: лига задаёт сложность
 * фраз. Новичок с рейтингом 1500 и отклонением 350 имеет консервативную
 * оценку 800 и получает материал A1 — а не C2 после одной случайной победы.
 */
create or replace function public.league_index_for_rating(p_league_rating integer)
returns integer
language sql
immutable
as $$
  select case
    when p_league_rating < 1200 then 0  -- A1
    when p_league_rating < 1500 then 1  -- A2
    when p_league_rating < 1800 then 2  -- B1
    when p_league_rating < 2100 then 3  -- B2
    when p_league_rating < 2400 then 4  -- C1
    else 5                              -- C2
  end;
$$;

-- Прежнее имя остаётся: на него ссылаются функции из миграции 0010 и
-- вызовы, которые незачем переписывать. Теперь это тонкая обёртка, чтобы
-- пороги жили в одном месте.
create or replace function public.league_index_for_elo(p_elo integer)
returns integer
language sql
immutable
as $$ select public.league_index_for_rating(p_elo); $$;

/**
 * Держит зеркала в согласии с источником истины. Срабатывает на любое
 * изменение rating/RD: league_rating зависит от обоих, и обновлять его
 * только при смене рейтинга значило бы, что после спокойного матча лига
 * не пересчиталась.
 */
create or replace function public.sync_rating_mirrors()
returns trigger
language plpgsql
as $$
begin
  new.elo := round(new.rating)::integer;
  new.league_rating := round(new.rating - 2.0 * new.rating_deviation)::integer;
  new.league := public.league_slug_for_elo(new.league_rating);
  new.cefr_level := public.cefr_level_for_elo(new.league_rating);
  return new;
end;
$$;

-- Прежний триггер слушал только elo и ставил лигу по нему — теперь elo сам
-- производная величина, и слушать его значит идти по кругу.
drop trigger if exists trg_sync_league_columns on user_languages;
drop trigger if exists trg_sync_rating_mirrors on user_languages;
create trigger trg_sync_rating_mirrors
  before insert or update of rating, rating_deviation on user_languages
  for each row execute function public.sync_rating_mirrors();

-- Пересчёт зеркал у всех существующих строк: триггер на UPDATE OF rating
-- срабатывает и тогда, когда значение не изменилось.
update user_languages set rating = rating;

alter table user_languages
  alter column league_rating set not null;

-- -------------------------------------------------------------------------
-- Применение рейтинга к паре игроков
-- -------------------------------------------------------------------------

/**
 * Обновляет рейтинг обоих участников матча по его исходу.
 *
 * p_score_a: 1 — победил A, 0.5 — ничья, 0 — победил B.
 * p_weight: доля, с которой засчитывается ИЗМЕНЕНИЕ рейтинга. 1.0 —
 *   доигранный матч. 0.5 — брошенный: цена выхода вдвое меньше цены
 *   поражения. Отклонение и волатильность при этом обновляются полностью:
 *   сведения о том, насколько игрок предсказуем, матч даёт настоящие, и
 *   урезать их незачем.
 *
 * Возвращает изменения рейтинга (a, b), округлённые до целых, — их
 * показывает экран итогов и хранят matches.elo_change_a/b.
 *
 * Оба игрока считаются от ОДНОГО среза «до матча»: если сначала обновить A,
 * а потом считать B уже от нового рейтинга A, результат зависел бы от
 * порядка и пара получала бы несимметричные изменения.
 */
create or replace function public.apply_glicko2_match(
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
  na record;
  nb record;
  periods_a double precision;
  periods_b double precision;
  new_rating_a double precision;
  new_rating_b double precision;
begin
  select rating, rating_deviation, volatility, rating_updated_at into a
    from user_languages
    where user_id = p_user_a and language_code = p_lang_a and role = 'learning'
    limit 1;
  select rating, rating_deviation, volatility, rating_updated_at into b
    from user_languages
    where user_id = p_user_b and language_code = p_lang_b and role = 'learning'
    limit 1;

  if a is null or b is null then
    change_a := 0;
    change_b := 0;
    return next;
    return;
  end if;

  periods_a := extract(epoch from (now() - a.rating_updated_at))
               / (86400.0 * public.glicko2_period_days());
  periods_b := extract(epoch from (now() - b.rating_updated_at))
               / (86400.0 * public.glicko2_period_days());

  select * into na from public.glicko2_update(
    a.rating, a.rating_deviation, a.volatility,
    b.rating, b.rating_deviation, p_score_a, periods_a);
  select * into nb from public.glicko2_update(
    b.rating, b.rating_deviation, b.volatility,
    a.rating, a.rating_deviation, 1.0 - p_score_a, periods_b);

  new_rating_a := a.rating + (na.rating - a.rating) * p_weight;
  new_rating_b := b.rating + (nb.rating - b.rating) * p_weight;

  update user_languages
    set rating = new_rating_a,
        rating_deviation = na.rating_deviation,
        volatility = na.volatility,
        rating_updated_at = now()
    where user_id = p_user_a and language_code = p_lang_a and role = 'learning';

  update user_languages
    set rating = new_rating_b,
        rating_deviation = nb.rating_deviation,
        volatility = nb.volatility,
        rating_updated_at = now()
    where user_id = p_user_b and language_code = p_lang_b and role = 'learning';

  change_a := round(new_rating_a - a.rating)::integer;
  change_b := round(new_rating_b - b.rating)::integer;
  return next;
end;
$$;

-- -------------------------------------------------------------------------
-- Завершение матча: тот же расчёт наград, рейтинг по Glicko-2
-- -------------------------------------------------------------------------

-- Тело функции скопировано из миграции 0006 без изменений, кроме блока
-- рейтинга: подсчёт выигранных раундов, определение победителя, монеты, XP
-- и очко Battle Pass остались прежними.
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

    -- Счёт матча в терминах Glicko-2: 1 — победа A, 0.5 — ничья, 0 — победа B.
    v_score_a := case when v_winner = v_match.player_a_id then 1.0
                      when v_winner is null then 0.5
                      else 0.0 end;
    select change_a, change_b into v_change_a, v_change_b
      from public.apply_glicko2_match(
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
-- Выход из боя: та же половинная цена, но по Glicko-2
-- -------------------------------------------------------------------------

-- Тело скопировано из миграции 0021 без изменений, кроме блока рейтинга.
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

    -- Ушедшему засчитывается поражение. Вес 0.5 — та же цена в половину,
    -- что и была на Эло: изменение рейтинга берётся наполовину, а
    -- отклонение и волатильность обновляются полностью, потому что
    -- сведения о предсказуемости игрока матч даёт настоящие.
    v_score_a := case when v_winner = v_match.player_a_id then 1.0 else 0.0 end;
    select change_a, change_b into v_change_a, v_change_b
      from public.apply_glicko2_match(
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
-- Всё остальное, что решало «какой у игрока уровень» по elo
-- -------------------------------------------------------------------------

/**
 * Ниже переписаны три функции из 0006 и 0010. Причина не косметическая:
 * раньше elo был и рейтингом, и мерой уровня, а теперь это зеркало
 * СЫРОГО рейтинга, который у всех примерно на 500 выше прежнего эло.
 * Оставить в них elo — значит выдать каждому игроку наборы слов и
 * строгость судьи на одну-две лиги выше, чем он заслужил. Уровень
 * везде считается по league_rating (rating - 2*RD) — по той же величине,
 * что показана игроку как его лига.
 *
 * Тела скопированы дословно, изменён только источник уровня.
 */

create or replace function public.purchase_word_pack(p_level_index integer, p_pack_index integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_league_rating integer;
  v_league_index integer;
  v_price integer;
  v_wallet currency_wallets%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if p_level_index < 0 or p_level_index > 5 or p_pack_index < 0 or p_pack_index > 9 then
    raise exception 'invalid pack';
  end if;
  if p_level_index = 0 and p_pack_index = 0 then
    raise exception 'pack_already_free';
  end if;

  if exists (
    select 1 from word_pack_purchases
    where user_id = v_uid and level_index = p_level_index and pack_index = p_pack_index
  ) then
    raise exception 'item already owned';
  end if;

  select league_rating into v_league_rating from user_languages
    where user_id = v_uid and role = 'learning' and is_active = true;
  v_league_index := public.league_index_for_rating(coalesce(v_league_rating, 1000));
  if p_level_index > v_league_index then
    raise exception 'league_locked';
  end if;

  v_price := public.word_pack_price(p_level_index, p_pack_index);

  select * into v_wallet from currency_wallets where user_id = v_uid for update;
  if not found then
    raise exception 'wallet not found for current user';
  end if;
  if v_wallet.soft_currency < v_price then
    raise exception 'insufficient_funds';
  end if;

  update currency_wallets set soft_currency = soft_currency - v_price where user_id = v_uid;
  insert into word_pack_purchases (user_id, level_index, pack_index) values (v_uid, p_level_index, p_pack_index)
    on conflict (user_id, level_index, pack_index) do nothing;
end;
$$;

create or replace function public.list_word_packs()
returns table (
  level_index integer,
  pack_index integer,
  price integer,
  owned boolean,
  league_locked boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_league_rating integer;
  v_league_index integer;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select league_rating into v_league_rating from user_languages
    where user_id = v_uid and role = 'learning' and is_active = true;
  v_league_index := public.league_index_for_rating(coalesce(v_league_rating, 1000));

  return query
  select
    lvl.level_index,
    pk.pack_index,
    public.word_pack_price(lvl.level_index, pk.pack_index),
    (lvl.level_index = 0 and pk.pack_index = 0)
      or exists (
        select 1 from word_pack_purchases wpp
        where wpp.user_id = v_uid and wpp.level_index = lvl.level_index and wpp.pack_index = pk.pack_index
      ),
    lvl.level_index > v_league_index
  from generate_series(0, 5) as lvl(level_index)
  cross join generate_series(0, 9) as pk(pack_index)
  order by lvl.level_index, pk.pack_index;
end;
$$;

/**
 * training_sessions.reference_elo — снимок уровня игрока на момент старта
 * сессии. Колонку не переименовываем (её пишет только эта функция и никто
 * не читает), но кладём в неё league_rating: смысл поля — «на каком уровне
 * человек тогда занимался», а это именно консервативная оценка.
 */
create or replace function public.start_training_session(p_target_language text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_wallet currency_wallets%rowtype;
  v_league_rating integer;
  v_session_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if not public.has_game_access(v_uid) then
    raise exception 'subscription_required';
  end if;

  v_wallet := public.regen_energy(v_uid);
  if v_wallet.energy_current < 1 then
    raise exception 'no_energy';
  end if;

  update currency_wallets set energy_current = energy_current - 1 where user_id = v_uid;

  select league_rating into v_league_rating from user_languages
    where user_id = v_uid and language_code = p_target_language and role = 'learning'
    limit 1;

  insert into training_sessions (user_id, target_language, reference_elo)
    values (v_uid, p_target_language, coalesce(v_league_rating, 1000))
    returning id into v_session_id;

  return jsonb_build_object('session_id', v_session_id, 'reference_elo', coalesce(v_league_rating, 1000));
end;
$$;

-- -------------------------------------------------------------------------
-- Права
-- -------------------------------------------------------------------------

-- apply_glicko2_match МЕНЯЕТ рейтинг. Postgres по умолчанию раздаёт EXECUTE
-- роли public на каждую новую функцию, то есть без этого отзыва любой
-- авторизованный игрок мог бы вызвать её напрямую и выставить себе любой
-- рейтинг. Её зовут только finalize_match и forfeit_match, а они security
-- definer и проверяют участие в матче.
revoke all on function public.apply_glicko2_match(uuid, text, uuid, text, double precision, double precision) from public;

-- Чистые функции расчёта читать и вызывать безопасно: они ничего не меняют
-- и ничего не знают о том, чей это рейтинг.
grant execute on function public.glicko2_update(
  double precision, double precision, double precision,
  double precision, double precision, double precision, double precision) to authenticated;
grant execute on function public.glicko2_decay(double precision, double precision, double precision) to authenticated;
grant execute on function public.league_index_for_rating(integer) to authenticated;

-- Явно, а не полагаясь на сохранение прав при create or replace.
grant execute on function public.finalize_match(uuid) to authenticated;
grant execute on function public.forfeit_match(uuid) to authenticated;
grant execute on function public.purchase_word_pack(integer, integer) to authenticated;
grant execute on function public.list_word_packs() to authenticated;
grant execute on function public.start_training_session(text) to authenticated;

