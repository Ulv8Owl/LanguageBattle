-- =========================================================================
-- СЕРИЯ ЗАНЯТИЙ («стрик»)
-- =========================================================================
--
-- ПОЧЕМУ СЧИТАЕТ СЕРВЕР. Серия — это прогресс, а прогресс в этой игре не
-- держит у себя клиент (раздел «Что ломается тихо»). Клиент сообщает
-- «сегодня занимался таким-то режимом» и показывает то, что вернул
-- сервер. Серия, которую игрок продлевает себе сам, — не серия.
--
-- ПОЧЕМУ ДАТУ ПРИСЫЛАЕТ КЛИЕНТ. Полночь у игрока своя: в UTC он уже
-- вчерашний, а на часах у него всё ещё вечер. Серия, оборванная посреди
-- вечера, — худшее, что может сделать эта механика, поэтому день берётся
-- местный. Но верить телефону на слово нельзя — часы переводит кто
-- угодно, — и присланная дата зажимается в ±1 сутки от UTC
-- (clamp_local_date). Этого хватает на все часовые пояса и не хватает ни
-- на что другое.
--
-- ПОЧЕМУ СЕРИЯ ПРИНАДЛЕЖИТ ЯЗЫКУ, А НЕ АККАУНТУ. Весь прогресс здесь
-- принадлежит изучаемому языку (миграция 0051), и серия не исключение. У
-- Duolingo серия одна на аккаунт, и перейдя на другой язык, игрок несёт
-- её с собой — то есть она перестаёт означать «я занимался ЭТИМ языком».
-- У нас каждый язык копит своё.

-- -------------------------------------------------------------------------
-- 1. Где живёт серия
-- -------------------------------------------------------------------------

alter table public.user_languages
  add column if not exists streak_current integer not null default 0,
  add column if not exists streak_best integer not null default 0,
  add column if not exists streak_last_day date,
  add column if not exists streak_freezes integer not null default 0,
  add column if not exists streak_broken_on date,
  add column if not exists streak_broken_len integer not null default 0,
  add column if not exists practice_days_total integer not null default 0,
  add column if not exists mode_counts jsonb not null default '{}'::jsonb;

comment on column public.user_languages.streak_last_day is
  'Последний МЕСТНЫЙ день с занятием. Местный, а не UTC: полночь у игрока своя.';
comment on column public.user_languages.streak_broken_on is
  'Первый день, который серию оборвал. Нужен починке: без него неизвестно, что чинить.';
comment on column public.user_languages.mode_counts is
  'Сколько занятий в каждом режиме. Отсюда «любимый режим» в Профиле.';

-- Календарь: по строке на закрытый день. Нужен не для счёта — счёт лежит
-- в user_languages, — а чтобы ПОКАЗАТЬ неделю и честно сказать, какой
-- день закрыт занятием, какой заморозкой, а какой починкой.
create table if not exists public.practice_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  language_code text not null,
  day date not null,
  -- practice | freeze | repair. Заморозку, потраченную молча, игрок
  -- воспринимает как сбой счёта: серия цела, а день пустой.
  source text not null default 'practice',
  mode text,
  created_at timestamptz not null default now(),
  primary key (user_id, language_code, day)
);

alter table public.practice_days enable row level security;

-- Читать — только свои. Писать клиенту нельзя вовсе: день, который
-- игрок закрывает себе сам, ничего не значит.
drop policy if exists practice_days_select_own on public.practice_days;
create policy practice_days_select_own on public.practice_days
  for select using (user_id = auth.uid());

grant select on public.practice_days to authenticated;

-- -------------------------------------------------------------------------
-- 2. Цены и вехи
-- -------------------------------------------------------------------------

-- Заморозка: держит серию за один пропущенный день. Больше двух в запасе
-- не бывает — иначе серия перестаёт что-либо значить, её просто покупают.
create or replace function public.streak_freeze_price()
returns integer language sql immutable as $$ select 120 $$;

create or replace function public.streak_max_freezes()
returns integer language sql immutable as $$ select 2 $$;

-- Починка дорожает вместе с тем, что чинят: вернуть серию из трёх дней
-- должно быть дешевле, чем из ста, иначе длинная серия ничего не стоит.
create or replace function public.streak_repair_price(p_len integer)
returns integer language sql immutable as $$
  select greatest(150, least(2000, 150 + coalesce(p_len, 0) * 25))
$$;

-- Сколько дней после обрыва серию ещё можно вернуть. Неделя — чтобы
-- уехавший в отпуск вернулся к своей серии, а не к пустому месту.
create or replace function public.streak_repair_window()
returns integer language sql immutable as $$ select 7 $$;

-- Вехи. Числа те же, что игрок держит в голове сам: неделя, две, месяц.
create or replace function public.streak_milestones()
returns integer[] language sql immutable as $$
  select array[7, 14, 30, 50, 100, 200, 365]
$$;

create or replace function public.streak_milestone_reward(p_days integer)
returns integer language sql immutable as $$
  select case p_days
    when 7 then 50
    when 14 then 100
    when 30 then 250
    when 50 then 400
    when 100 then 1000
    when 200 then 2000
    when 365 then 5000
    else 0
  end
$$;

grant execute on function public.streak_freeze_price() to authenticated;
grant execute on function public.streak_max_freezes() to authenticated;
grant execute on function public.streak_repair_price(integer) to authenticated;
grant execute on function public.streak_repair_window() to authenticated;
grant execute on function public.streak_milestones() to authenticated;
grant execute on function public.streak_milestone_reward(integer) to authenticated;

-- -------------------------------------------------------------------------
-- 3. Местная дата, которой можно верить ровно настолько, насколько нужно
-- -------------------------------------------------------------------------

create or replace function public.clamp_local_date(p_local_date date)
returns date
language sql
stable
as $$
  select least(
    greatest(
      coalesce(p_local_date, (now() at time zone 'utc')::date),
      (now() at time zone 'utc')::date - 1
    ),
    (now() at time zone 'utc')::date + 1
  )
$$;

grant execute on function public.clamp_local_date(date) to authenticated;

-- -------------------------------------------------------------------------
-- 4. Привести серию к сегодняшнему дню
-- -------------------------------------------------------------------------

-- ВЫЗЫВАЕТСЯ И ПРИ ЧТЕНИИ, И ПРИ ЗАПИСИ, И ЭТО НЕ ИЗБЫТОЧНО. Серия
-- сгорает не от действия игрока, а от его бездействия: если считать её
-- только при занятии, экран будет показывать вчерашнее число тому, у
-- кого она уже сгорела.
create or replace function public.settle_streak(
  p_user_id uuid,
  p_language text,
  p_today date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_last date;
  v_current integer;
  v_freezes integer;
  v_missed integer;
begin
  select streak_last_day, streak_current, streak_freezes
    into v_last, v_current, v_freezes
  from user_languages
  where user_id = p_user_id and role = 'learning' and language_code = p_language
  for update;

  if not found or v_last is null or v_current = 0 then
    return;
  end if;
  -- Сегодня или раньше — гасить нечего. Дата из будущего сюда попасть не
  -- может: её зажал clamp_local_date.
  if p_today <= v_last then
    return;
  end if;

  -- Полностью пропущенные дни: вчерашний ещё не пропущен, пока идёт
  -- сегодняшний.
  v_missed := (p_today - v_last) - 1;
  if v_missed <= 0 then
    return;
  end if;

  -- Заморозки гасят пропуски по одному, от старого к новому.
  while v_missed > 0 and v_freezes > 0 loop
    v_last := v_last + 1;
    v_freezes := v_freezes - 1;
    v_missed := v_missed - 1;
    insert into practice_days (user_id, language_code, day, source)
    values (p_user_id, p_language, v_last, 'freeze')
    on conflict do nothing;
  end loop;

  if v_missed > 0 then
    -- Сгорела. Запоминаем ЧТО и КОГДА — иначе чинить будет нечего.
    update user_languages
    set streak_freezes = v_freezes,
        streak_last_day = v_last,
        streak_broken_on = v_last + 1,
        streak_broken_len = v_current,
        streak_current = 0
    where user_id = p_user_id and role = 'learning' and language_code = p_language;
  else
    update user_languages
    set streak_freezes = v_freezes,
        streak_last_day = v_last
    where user_id = p_user_id and role = 'learning' and language_code = p_language;
  end if;
end;
$$;

-- -------------------------------------------------------------------------
-- 5. Отметить занятие
-- -------------------------------------------------------------------------

create or replace function public.record_practice_day(
  p_local_date date,
  p_mode text default 'battle'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lang text;
  v_day date;
  v_last date;
  v_current integer;
  v_best integer;
  v_new integer;
  v_reward integer := 0;
  v_milestone integer := 0;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  v_lang := public.active_learning_language(v_uid);
  if v_lang is null then
    raise exception 'no_learning_language';
  end if;
  v_day := public.clamp_local_date(p_local_date);

  -- Режим считаем ВСЕГДА, даже если день уже закрыт: «любимый режим»
  -- считает занятия, а не дни.
  update user_languages
  set mode_counts = jsonb_set(
        mode_counts,
        array[coalesce(nullif(p_mode, ''), 'battle')],
        to_jsonb(coalesce((mode_counts ->> coalesce(nullif(p_mode, ''), 'battle'))::integer, 0) + 1)
      )
  where user_id = v_uid and role = 'learning' and language_code = v_lang;

  perform public.settle_streak(v_uid, v_lang, v_day);

  select streak_last_day, streak_current, streak_best
    into v_last, v_current, v_best
  from user_languages
  where user_id = v_uid and role = 'learning' and language_code = v_lang
  for update;

  if v_last is not null and v_day <= v_last then
    -- День уже закрыт. Второе занятие за день серию не удлиняет — иначе
    -- «серия» означала бы число заходов, а не число дней.
    return public.streak_state(v_day);
  end if;

  v_new := case
    when v_last is null then 1
    when v_day - v_last = 1 then coalesce(v_current, 0) + 1
    else 1
  end;

  insert into practice_days (user_id, language_code, day, source, mode)
  values (v_uid, v_lang, v_day, 'practice', nullif(p_mode, ''))
  on conflict (user_id, language_code, day) do update
    set source = 'practice',
        mode = coalesce(excluded.mode, practice_days.mode);

  if v_new = any(public.streak_milestones()) then
    v_milestone := v_new;
    v_reward := public.streak_milestone_reward(v_new);
    perform public.grant_language_reward(v_uid, v_lang, v_reward, 0);
  end if;

  update user_languages
  set streak_current = v_new,
      streak_best = greatest(coalesce(v_best, 0), v_new),
      streak_last_day = v_day,
      practice_days_total = practice_days_total + 1,
      -- Серия пошла заново — чинить больше нечего.
      streak_broken_on = null,
      streak_broken_len = 0
  where user_id = v_uid and role = 'learning' and language_code = v_lang;

  return public.streak_state(v_day)
    || jsonb_build_object('milestone', v_milestone, 'milestone_reward', v_reward);
end;
$$;

grant execute on function public.record_practice_day(date, text) to authenticated;

-- -------------------------------------------------------------------------
-- 6. Состояние серии одним снимком
-- -------------------------------------------------------------------------

create or replace function public.streak_state(p_local_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lang text;
  v_day date;
  v_row user_languages%rowtype;
  v_week jsonb;
  v_languages jsonb;
  v_next integer := null;
  v_coins integer := 0;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  v_lang := public.active_learning_language(v_uid);
  v_day := public.clamp_local_date(p_local_date);
  if v_lang is null then
    return jsonb_build_object('language', null, 'current', 0, 'best', 0);
  end if;

  perform public.settle_streak(v_uid, v_lang, v_day);

  select * into v_row
  from user_languages
  where user_id = v_uid and role = 'learning' and language_code = v_lang;

  -- Неделя: семь дней подряд, заканчивая сегодняшним. Пустой день —
  -- тоже ответ, поэтому дни берутся из ряда, а не из таблицы.
  select jsonb_agg(
           jsonb_build_object(
             'day', d::date,
             'source', pd.source,
             'done', pd.day is not null
           ) order by d
         )
    into v_week
  from generate_series(v_day - 6, v_day, interval '1 day') d
  left join practice_days pd
    on pd.user_id = v_uid and pd.language_code = v_lang and pd.day = d::date;

  -- Серии ДРУГИХ языков. Этого у Duolingo нет вовсе: там серия одна на
  -- аккаунт, и сменив язык, игрок несёт её с собой — то есть она
  -- перестаёт означать «я занимался этим языком».
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'language', language_code,
             'current', streak_current,
             'best', streak_best
           ) order by streak_current desc, language_code
         ), '[]'::jsonb)
    into v_languages
  from user_languages
  where user_id = v_uid and role = 'learning' and hidden_at is null;

  select min(m) into v_next
  from unnest(public.streak_milestones()) m
  where m > v_row.streak_current;

  v_coins := coalesce(v_row.coins, 0);

  return jsonb_build_object(
    'language', v_lang,
    'today', v_day,
    'current', coalesce(v_row.streak_current, 0),
    'best', coalesce(v_row.streak_best, 0),
    'last_day', v_row.streak_last_day,
    'today_done', v_row.streak_last_day = v_day,
    'total_days', coalesce(v_row.practice_days_total, 0),
    'freezes', coalesce(v_row.streak_freezes, 0),
    'freeze_price', public.streak_freeze_price(),
    'max_freezes', public.streak_max_freezes(),
    'broken_on', v_row.streak_broken_on,
    'broken_len', coalesce(v_row.streak_broken_len, 0),
    'repair_price', public.streak_repair_price(v_row.streak_broken_len),
    'repair_available',
      v_row.streak_broken_on is not null
      and coalesce(v_row.streak_broken_len, 0) > 0
      and v_day - v_row.streak_broken_on <= public.streak_repair_window(),
    'coins', v_coins,
    'next_milestone', v_next,
    'next_milestone_reward', public.streak_milestone_reward(v_next),
    'milestones', to_jsonb(public.streak_milestones()),
    'mode_counts', coalesce(v_row.mode_counts, '{}'::jsonb),
    'week', coalesce(v_week, '[]'::jsonb),
    'languages', v_languages
  );
end;
$$;

grant execute on function public.streak_state(date) to authenticated;

-- -------------------------------------------------------------------------
-- 7. Заморозка и починка
-- -------------------------------------------------------------------------

create or replace function public.buy_streak_freeze()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lang text;
  v_coins integer;
  v_freezes integer;
  v_price integer := public.streak_freeze_price();
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  v_lang := public.active_learning_language(v_uid);
  if v_lang is null then
    raise exception 'no_learning_language';
  end if;

  select coins, streak_freezes into v_coins, v_freezes
  from user_languages
  where user_id = v_uid and role = 'learning' and language_code = v_lang
  for update;

  if v_freezes >= public.streak_max_freezes() then
    raise exception 'freezes_full';
  end if;
  if coalesce(v_coins, 0) < v_price then
    raise exception 'insufficient_funds';
  end if;

  update user_languages
  set coins = coins - v_price,
      streak_freezes = streak_freezes + 1
  where user_id = v_uid and role = 'learning' and language_code = v_lang;

  return public.streak_state(null);
end;
$$;

grant execute on function public.buy_streak_freeze() to authenticated;

-- Починка возвращает ту серию, что была, и закрывает пропущенные дни
-- пометкой repair: в календаре видно, что день куплен, а не пройден.
create or replace function public.repair_streak(p_local_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lang text;
  v_day date;
  v_row user_languages%rowtype;
  v_price integer;
  v_cursor date;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  v_lang := public.active_learning_language(v_uid);
  if v_lang is null then
    raise exception 'no_learning_language';
  end if;
  v_day := public.clamp_local_date(p_local_date);

  select * into v_row
  from user_languages
  where user_id = v_uid and role = 'learning' and language_code = v_lang
  for update;

  if v_row.streak_broken_on is null or coalesce(v_row.streak_broken_len, 0) = 0 then
    raise exception 'nothing_to_repair';
  end if;
  if v_day - v_row.streak_broken_on > public.streak_repair_window() then
    raise exception 'repair_expired';
  end if;

  v_price := public.streak_repair_price(v_row.streak_broken_len);
  if coalesce(v_row.coins, 0) < v_price then
    raise exception 'insufficient_funds';
  end if;

  -- Закрываем дыру: от дня обрыва до вчерашнего включительно.
  v_cursor := v_row.streak_broken_on;
  while v_cursor < v_day loop
    insert into practice_days (user_id, language_code, day, source)
    values (v_uid, v_lang, v_cursor, 'repair')
    on conflict (user_id, language_code, day) do nothing;
    v_cursor := v_cursor + 1;
  end loop;

  update user_languages
  set coins = coins - v_price,
      streak_current = v_row.streak_broken_len + (v_day - v_row.streak_broken_on),
      streak_best = greatest(
        coalesce(v_row.streak_best, 0),
        v_row.streak_broken_len + (v_day - v_row.streak_broken_on)
      ),
      streak_last_day = v_day - 1,
      streak_broken_on = null,
      streak_broken_len = 0
  where user_id = v_uid and role = 'learning' and language_code = v_lang;

  return public.streak_state(v_day);
end;
$$;

grant execute on function public.repair_streak(date) to authenticated;
