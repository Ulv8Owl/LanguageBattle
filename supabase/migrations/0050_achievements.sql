-- Достижения. Пока ровно одно: «Неудержимый» — продержаться в Одиночной
-- Игре N раундов подряд.
--
-- ПОЧЕМУ ОДНО, А НЕ СРАЗУ ДЕСЯТЬ. Достижение, придуманное «чтобы было»,
-- ничего не измеряет и выдаётся всем подряд. Здесь заведён механизм и одна
-- настоящая ступенчатая награда; остальные добавляются строкой в CHECK и
-- своей выдающей функцией, когда станет понятно, за что их давать.
--
-- СТУПЕНИ ХРАНЯТСЯ КАЖДАЯ СВОЕЙ СТРОКОЙ, а не одним «лучшим» числом в
-- профиле. Взяв максимум, мы потеряли бы дату каждой ступени, а она
-- единственное, чем достижение отличается от счётчика в статистике.

create table if not exists public.achievements (
  user_id uuid not null references public.users(id) on delete cascade,
  -- Вид достижения. Список растёт и НЕ УМЕНЬШАЕТСЯ: выбросив значение из
  -- CHECK, мы сломали бы строки, которые у игроков уже есть.
  kind text not null check (kind in ('unstoppable')),
  -- Ступень: для «Неудержимого» это число раундов (5, 10, 15 …).
  tier integer not null check (tier > 0),
  earned_at timestamptz not null default now(),
  primary key (user_id, kind, tier)
);

alter table public.achievements enable row level security;

-- Читать — только свои. Писать клиенту нельзя вовсе: достижение, которое
-- выдаёт себе сам клиент, не достижение, а настройка.
drop policy if exists achievements_select_own on public.achievements;
create policy achievements_select_own on public.achievements
  for select using (user_id = auth.uid());

-- Шаг ступеней «Неудержимого». Пять раундов — это уже не «зашёл посмотреть»,
-- и дальше шаг тот же, чтобы награда не разрежалась к концу.
create or replace function public.unstoppable_step()
returns integer language sql immutable as $$ select 5 $$;

/*
 * Выдаёт все ступени «Неудержимого», заслуженные серией из p_rounds раундов.
 *
 * ВЫДАЁТ СРАЗУ ВСЕ НЕДОСТАЮЩИЕ, а не только последнюю: игрок мог пройти
 * пятый раунд в тот момент, когда приложение потеряло сеть, и вернуться к
 * нам уже на одиннадцатом. Пропущенная пятёрка от этого не перестаёт быть
 * заслуженной.
 *
 * ИДЕМПОТЕНТНА: повторный вызов на том же числе раундов не выдаёт ничего.
 * Возвращает только НОВЫЕ ступени — их и показывает игроку клиент.
 */
create or replace function public.award_unstoppable(p_rounds integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_step integer := public.unstoppable_step();
  v_new integer[];
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if p_rounds is null or p_rounds < v_step then
    return jsonb_build_object('new_tiers', '[]'::jsonb);
  end if;

  with earned as (
    insert into achievements (user_id, kind, tier)
    select v_uid, 'unstoppable', tier
    from generate_series(v_step, p_rounds - (p_rounds % v_step), v_step) as tier
    on conflict (user_id, kind, tier) do nothing
    returning tier
  )
  select coalesce(array_agg(tier order by tier), '{}') into v_new from earned;

  return jsonb_build_object('new_tiers', to_jsonb(v_new));
end;
$$;

grant execute on function public.unstoppable_step() to authenticated;
grant execute on function public.award_unstoppable(integer) to authenticated;
