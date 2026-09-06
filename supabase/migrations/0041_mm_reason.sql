-- Поиск соперника объясняет, почему никого не нашёл.
--
-- ЧТО БЫЛО СЛОМАНО. Окно рейтинга росло 100 → 250 → 600 и на этом
-- останавливалось. Разница в 900 очков (один игрок прошёл проверку уровня
-- на B1 и получил 1500, другой остался новичком с 600) не покрывалась
-- НИКОГДА: сколько ни жди, соперник рядом в очереди, а матча нет.
--
-- Это не настройка баланса, а тупик: поиск, который не может завершиться
-- успехом ни при каком ожидании, выглядит для игрока как «режим не
-- работает». В игре с небольшим онлайном неравный соперник лучше, чем
-- никакого, и последний шаг окна поэтому теперь не ограничен — клиент
-- присылает заведомо большое значение.
--
-- ВТОРАЯ ЧАСТЬ: причина отказа. Раньше mm_search на неудаче отвечал
-- {found: false, status: 'searching'} — и всё. Отличить «в очереди никого»
-- от «соперник есть, но рейтинг далеко» было нечем, а на экране это
-- одинаковый крутящийся индикатор. Теперь функция считает, сколько
-- соперников подходит по языку, и насколько далёк ближайший по рейтингу.

-- Подходят ли два тикета друг другу ПО ЯЗЫКАМ.
--
-- Вынесено в функцию, потому что теперь этот фильтр нужен дважды: в самом
-- поиске и в подсчёте «сколько соперников подходило бы, если бы не
-- рейтинг». Две копии одного условия разъехались бы на первой же правке, а
-- разъехавшись, показывали бы игроку объяснение, не совпадающее с
-- поведением поиска.
create or replace function public.mm_languages_fit(
  a matchmaking_tickets,
  b matchmaking_tickets
) returns boolean
language sql
immutable
as $$
  select case a.game_mode
    -- Состязание: достаточно общего изучаемого языка. Тумблер «только
    -- соотечественники» уважается, если его включила любая из сторон.
    when 'sparring' then
      b.target_language = a.target_language
      and (
        (not a.countrymen_only and not b.countrymen_only)
        or b.native_language = a.native_language
      )
    -- Дуэль: строгая обратная пара.
    when 'native_duel' then
      b.target_language = a.native_language
      and b.native_language = a.target_language
    else false
  end;
$$;

create or replace function public.mm_search(p_ticket_id uuid, p_elo_window integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_me matchmaking_tickets%rowtype;
  v_other matchmaking_tickets%rowtype;
  v_match_id uuid;
  v_language_pair text;
  v_by_language integer;
  v_nearest integer;
begin
  select * into v_me from matchmaking_tickets where id = p_ticket_id for update;
  if not found or v_me.user_id <> v_uid then
    raise exception 'ticket not found';
  end if;

  -- Соперника уже нашли (нас нашла встречная сторона) — отдаём матч.
  if v_me.status in ('found','accepted') and v_me.match_id is not null then
    return jsonb_build_object('found', true, 'match_id', v_me.match_id);
  end if;
  if v_me.status <> 'searching' then
    return jsonb_build_object('found', false, 'status', v_me.status);
  end if;
  if v_me.expires_at is not null and v_me.expires_at < now() then
    update matchmaking_tickets set status = 'expired' where id = p_ticket_id;
    return jsonb_build_object('found', false, 'status', 'expired');
  end if;

  select * into v_other
  from matchmaking_tickets t
  where t.status = 'searching'
    and t.id <> v_me.id
    and t.user_id <> v_me.user_id
    and t.game_mode = v_me.game_mode
    and (t.expires_at is null or t.expires_at > now())
    and abs(coalesce(t.elo, 1000) - coalesce(v_me.elo, 1000)) <= p_elo_window
    and public.mm_languages_fit(v_me, t)
  order by abs(coalesce(t.elo, 1000) - coalesce(v_me.elo, 1000)), t.created_at
  limit 1
  for update skip locked;

  if not found then
    -- Считаем, кто подходил бы по языку, если бы не рейтинг. Ровно тот же
    -- фильтр, минус окно: расхождение между этими двумя числами и есть
    -- ответ на вопрос «почему никого нет».
    select count(*), min(abs(coalesce(t.elo, 1000) - coalesce(v_me.elo, 1000)))
      into v_by_language, v_nearest
      from matchmaking_tickets t
     where t.status = 'searching'
       and t.id <> v_me.id
       and t.user_id <> v_me.user_id
       and t.game_mode = v_me.game_mode
       and (t.expires_at is null or t.expires_at > now())
       and public.mm_languages_fit(v_me, t);

    return jsonb_build_object(
      'found', false,
      'status', 'searching',
      -- Сколько соперников подходит по языку прямо сейчас.
      'by_language', coalesce(v_by_language, 0),
      -- На сколько очков далёк ближайший из них. null — таких нет вовсе.
      'nearest_gap', v_nearest,
      'elo_window', p_elo_window
    );
  end if;

  if v_me.game_mode = 'native_duel' then
    -- Конвенция language_pair для Дуэли: "родной A - родной B"
    -- (см. supabase/README.md и MatchData.languageForSlot).
    v_language_pair := v_me.native_language || '-' || v_other.native_language;
  else
    v_language_pair := v_me.target_language;
  end if;

  insert into matches (player_a_id, player_b_id, game_mode, language_pair, status)
    values (v_uid, v_other.user_id, v_me.game_mode, v_language_pair, 'matchmaking')
    returning id into v_match_id;

  update matchmaking_tickets set
    status = 'found', match_id = v_match_id, opponent_ticket_id = v_other.id, notified_at = now()
    where id = v_me.id;
  update matchmaking_tickets set
    status = 'found', match_id = v_match_id, opponent_ticket_id = v_me.id, notified_at = now()
    where id = v_other.id;

  return jsonb_build_object('found', true, 'match_id', v_match_id);
end;
$$;

grant execute on function public.mm_search(uuid, integer) to authenticated;
