-- =========================================================================
-- Энергия платит за ВЫЗОВЫ, а не за вход в режим.
--
-- Как было. start_training_session списывал 1 энергию за сам факт входа в
-- Одиночную Игру. Пять раундов, десять голосовых, два вызова
-- распознавания на раунд — и всё это стоило столько же, сколько заход,
-- из которого игрок вышел на первой фразе. Расход не имел никакого
-- отношения к тому, за что мы платим провайдерам.
--
-- Как стало. Платными считаются ровно те действия, которые стоят денег:
--   * распознавание речи — 1 энергия;
--   * ответ языковой модели — 2 энергии.
-- И только когда ответ ПОЛУЧЕН: за молчание провайдера, повторный прогон
-- по уже сохранённому транскрипту и за собственные сбои игрок не платит.
-- Считает это воркер (evaluate-recording), потому что только он знает,
-- дошёл ли вызов до провайдера и вернулся ли ответ.
--
-- Запас поднят с 10 до 50. При старой цене «1 за вход» десятки хватало на
-- десять сессий; при новой одна сессия из пяти раундов стоит около десяти
-- энергий сама по себе, и прежний запас кончался бы на первой же.
-- =========================================================================

-- И потолок, и стартовый запас: новый кошелёк заводится сразу полным.
-- Оставить energy_current на прежней десятке значило бы выдавать новичку
-- пятую часть бака и молча делать первую сессию последней.
alter table currency_wallets
  alter column energy_max set default 50,
  alter column energy_current set default 50;

-- Существующим кошелькам поднимаем и потолок, и текущий запас: цена
-- выросла в тот же момент, и оставить игрока с десяткой при новом расходе
-- значило бы отобрать у него режим на ровном месте.
update currency_wallets
   set energy_max = greatest(energy_max, 50),
       energy_current = greatest(energy_current, 50)
 where energy_max < 50;

-- =========================================================================
-- training_sessions.is_placement — чтобы воркер знал, с кого не брать.
--
-- До сих пор про проверку уровня знала только start_training_session: она
-- получала флаг аргументом, не пускала повторную проверку и на этом
-- забывала о нём. Воркеру этого мало: он списывает энергию уже ПОСЛЕ
-- ответа провайдера, а проверка уровня бесплатна целиком. Определить её по
-- косвенным признакам (одна фраза, нет lиги) нельзя — это гадание, и
-- ошибётся оно ровно в онбординге, где промах заметнее всего.
-- =========================================================================
alter table training_sessions
  add column if not exists is_placement boolean not null default false;

comment on column training_sessions.is_placement is
  'Сессия — проверка уровня при регистрации. Такая сессия не тратит '
  'энергию ни на вход, ни на вызовы провайдеров: провалить проверку и '
  'пройти её заново игрок должен мочь, ещё не начав играть.';

-- =========================================================================
-- spend_energy — списание за один платный вызов.
--
-- Зовёт её ТОЛЬКО воркер, из Edge Function под service_role: клиент не
-- знает и не должен знать, дошёл ли запрос до провайдера. Отсюда и
-- revoke: с ролью authenticated эта функция стала бы способом обнулить
-- себе энергию (или, при отрицательном p_amount, начислить).
--
-- НЕ ПАДАЕТ, когда энергии не хватило: списывает сколько есть и
-- возвращает остаток. Оценка ответа к этому моменту уже сделана, деньги
-- провайдеру уже заплачены, и уронить из-за учёта запись результата
-- значило бы наказать игрока за нашу же бухгалтерию. Не пустить его в
-- следующую сессию — задача start_training_session, и она эту проверку
-- делает до того, как что-либо потрачено.
-- =========================================================================
create or replace function public.spend_energy(
  p_user_id uuid,
  p_amount integer,
  p_reason text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_left integer;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'spend_energy: amount must be positive, got %', p_amount;
  end if;

  perform public.regen_energy(p_user_id);

  update currency_wallets
     set energy_current = greatest(0, energy_current - p_amount)
   where user_id = p_user_id
  returning energy_current into v_left;

  return v_left;
end;
$$;

revoke all on function public.spend_energy(uuid, integer, text) from public;
revoke all on function public.spend_energy(uuid, integer, text) from authenticated;
grant execute on function public.spend_energy(uuid, integer, text) to service_role;

-- =========================================================================
-- start_training_session больше не берёт плату за вход.
--
-- Проверка остатка при этом ОСТАЛАСЬ: с нулём энергии в режим не пускаем.
-- Иначе игрок с пустым запасом заходил бы и играл сколько угодно —
-- списание идёт после ответа провайдера и остановить его уже не может.
-- Порог в 1 — это «хватит хотя бы на одно распознавание».
-- =========================================================================
create or replace function public.start_training_session(
  p_target_language text,
  p_is_placement boolean default false
)
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
  v_placement_open boolean;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if not public.has_game_access(v_uid) then
    raise exception 'subscription_required';
  end if;

  if p_is_placement then
    -- Проверка уровня по-прежнему бесплатна целиком: провалить её и
    -- захотеть пройти заново — нормальный сценарий онбординга, и упереться
    -- в пустой запас там значило бы застрять, не начав играть.
    select not placement_done into v_placement_open from user_languages
      where user_id = v_uid and language_code = p_target_language and role = 'learning'
      limit 1;
    if coalesce(v_placement_open, false) = false then
      raise exception 'placement_already_done';
    end if;
  else
    v_wallet := public.regen_energy(v_uid);
    if v_wallet.energy_current < 1 then
      raise exception 'no_energy';
    end if;
  end if;

  select league_rating into v_league_rating from user_languages
    where user_id = v_uid and language_code = p_target_language and role = 'learning'
    limit 1;

  insert into training_sessions (user_id, target_language, reference_elo, is_placement)
    values (v_uid, p_target_language, coalesce(v_league_rating, 1000), p_is_placement)
    returning id into v_session_id;

  return jsonb_build_object('session_id', v_session_id, 'reference_elo', coalesce(v_league_rating, 1000));
end;
$$;

grant execute on function public.start_training_session(text, boolean) to authenticated;

comment on column currency_wallets.energy_current is
  'Энергия. Тратится не на вход в режим, а на платные вызовы Одиночной '
  'Игры: 1 за распознавание речи и 2 за ответ языковой модели, и только '
  'когда ответ получен (списывает воркер через spend_energy). Проверка '
  'уровня бесплатна, Дуэль и Спарринг энергию не тратят.';
