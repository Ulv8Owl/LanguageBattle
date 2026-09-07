-- Очередь поиска живёт три минуты, а не тридцать пять секунд.
--
-- ЧТО БЫЛО СЛОМАНО. Тикет протухал через 35 секунд, а экран сдавался через
-- 30. Матч мог состояться только если ОБА игрока стоят в очереди в одном и
-- том же получасовом окне длиной в полминуты. В игре с небольшим онлайном
-- это значит «никогда»: два человека, открывшие Состязание с разницей в
-- минуту, не встречались, хотя оба хотели играть и подходили друг другу по
-- языку и рейтингу.
--
-- Языковой фильтр здесь ни при чём — он проверен отдельно и работает: два
-- тикета с парой ru→en находят друг друга сразу, как только окно рейтинга
-- открывается. Ломалось именно время.
--
-- Три минуты — это компромисс. Больше — и в очереди начнут стоять тикеты
-- игроков, которые давно закрыли приложение: их находят, а подтвердить
-- матч некому, и соперник ждёт впустую. Меньше — возвращается исходная
-- задача. Не подтверждённый матч при этом не пропадает: mm_cancel
-- (миграция 0007) возвращает второй тикет в 'searching'.
create or replace function public.mm_enqueue(
  p_game_mode text,
  p_native_language text,
  p_target_language text,
  p_countrymen_only boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_elo integer;
  v_ticket_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if not public.has_game_access(v_uid) then
    raise exception 'subscription_required';
  end if;

  update matchmaking_tickets set status = 'cancelled'
    where user_id = v_uid and status in ('searching','found');

  select elo into v_elo from user_languages
    where user_id = v_uid and language_code = p_target_language and role = 'learning'
    limit 1;

  insert into matchmaking_tickets (
    user_id, game_mode, native_language, target_language,
    countrymen_only, elo, status, expires_at
  ) values (
    v_uid, p_game_mode, p_native_language, p_target_language,
    coalesce(p_countrymen_only, false), coalesce(v_elo, 1000), 'searching',
    now() + interval '3 minutes'
  ) returning id into v_ticket_id;

  return v_ticket_id;
end;
$$;

grant execute on function public.mm_enqueue(text, text, text, boolean) to authenticated;
