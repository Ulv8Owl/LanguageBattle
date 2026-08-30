-- Тренировка перестала быть «пройди всю колоду за раз».
--
-- Колода — по-прежнему 100 карточек, но за одну тренировку игроку выдаётся
-- только часть (по умолчанию 20, настраивается от 10 до 50 с шагом 10).
-- Следующий заход в ту же колоду продолжает с того места, где остановились:
-- счётчик показывает не «1 / 100», а «21 / 100». Когда пройдена вся сотня,
-- колода сбрасывается и начинается заново.
--
-- Прогресс и настройка живут на сервере, а не на устройстве: и то и другое
-- относится к аккаунту, а не к телефону, — иначе на втором телефоне игрок
-- начинал бы колоду с начала.

alter table users
  add column if not exists training_deck_size smallint not null default 20;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'users_training_deck_size_check'
  ) then
    alter table users
      add constraint users_training_deck_size_check
      check (training_deck_size between 10 and 50 and training_deck_size % 10 = 0);
  end if;
end $$;

comment on column users.training_deck_size is
  'Сколько карточек выдаётся за одну тренировку: 10..50 с шагом 10.';

-- Сколько карточек колоды игрок уже прошёл. Одна строка на колоду.
create table if not exists user_pack_progress (
  user_id uuid not null references users(id) on delete cascade,
  level_index smallint not null check (level_index between 0 and 5),
  pack_index smallint not null check (pack_index between 0 and 9),
  -- Позиция в колоде: с какой карточки начнётся следующая тренировка.
  -- Доходит до 100 и сбрасывается в 0 — колода начинается заново.
  served_count smallint not null default 0 check (served_count between 0 and 100),
  updated_at timestamptz not null default now(),
  primary key (user_id, level_index, pack_index)
);

alter table user_pack_progress enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where tablename = 'user_pack_progress' and policyname = 'own progress: read'
  ) then
    create policy "own progress: read" on user_pack_progress
      for select to authenticated using (user_id = auth.uid());
  end if;
  if not exists (
    select 1 from pg_policies
    where tablename = 'user_pack_progress' and policyname = 'own progress: write'
  ) then
    create policy "own progress: write" on user_pack_progress
      for insert to authenticated with check (user_id = auth.uid());
  end if;
  if not exists (
    select 1 from pg_policies
    where tablename = 'user_pack_progress' and policyname = 'own progress: update'
  ) then
    create policy "own progress: update" on user_pack_progress
      for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
  end if;
end $$;

/**
 * Сдвигает прогресс колоды на пройденные карточки и возвращает новое
 * значение. Дойдя до 100, обнуляется — колода начинается заново.
 *
 * Функцией, а не UPDATE с клиента: сброс на сотне и «не больше 100» это
 * одно правило, и держать его в двух местах значит однажды получить
 * колоду, которая не сбрасывается.
 */
create or replace function public.advance_pack_progress(
  p_level_index smallint,
  p_pack_index smallint,
  p_completed smallint
)
returns smallint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next smallint;
begin
  insert into user_pack_progress (user_id, level_index, pack_index, served_count)
    values (auth.uid(), p_level_index, p_pack_index, least(100, greatest(0, p_completed)))
  on conflict (user_id, level_index, pack_index) do update
    set served_count = least(100, user_pack_progress.served_count + greatest(0, p_completed)),
        updated_at = now()
  returning served_count into v_next;

  if v_next >= 100 then
    update user_pack_progress
      set served_count = 0, updated_at = now()
      where user_id = auth.uid()
        and level_index = p_level_index
        and pack_index = p_pack_index;
    return 0;
  end if;

  return v_next;
end;
$$;

grant execute on function public.advance_pack_progress(smallint, smallint, smallint) to authenticated;
