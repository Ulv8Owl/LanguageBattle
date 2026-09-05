-- =========================================================================
-- Поэлементная оценка ответа.
--
-- Фраза раунда теперь приходит из банка разбитой на элементы (датасет
-- assets/cefr, разделитель «|»), и оценку считает не языковая модель, а
-- прямой подсчёт: сколько элементов игрок произнёс, а сколько потерял.
-- Судья-LLM выключен переменной окружения JUDGE_ENABLED и код его цел —
-- см. supabase/functions/_shared/evaluateGrammar.ts.
--
-- Схеме от этого нужно ровно две вещи: разрешить новую категорию ошибки и
-- дать место для доли подсказок в Одиночной Игре.
-- =========================================================================

-- -------------------------------------------------------------------------
-- Новая категория ошибки: непроизнесённый элемент
-- -------------------------------------------------------------------------

-- Раньше категорий было три, и все три — про то, ЧТО не так со словом
-- (грамматика, орфография, стиль). Их выставлял судья. Поэлементная оценка
-- отвечает на другой вопрос — произнесён элемент или нет, — и вписывать её
-- в 'grammar' значило бы называть грамматической ошибкой пропуск куска
-- фразы. Отсюда отдельная категория.
--
-- Старые три остаются: судью выключили, а не удалили, и записи, сделанные
-- им раньше, должны продолжать читаться.
alter table grammar_errors drop constraint if exists grammar_errors_category_check;
alter table grammar_errors
  add constraint grammar_errors_category_check
  check (category in ('grammar', 'spelling', 'style', 'element'));

comment on column grammar_errors.category is
  'grammar | spelling | style — от LLM-судьи; element — элемент фразы, '
  'который игрок не произнёс (поэлементная оценка, миграция 0029).';

comment on column grammar_errors.message is
  'Текст объяснения от судьи. У категории element ПУСТ намеренно: '
  'пояснение к элементу лежит в датасете (assets/cefr/explanations_*.txt) '
  'и показывается клиентом по тапу, а не пересылается с сервера в каждом '
  'раунде.';

-- -------------------------------------------------------------------------
-- Подсказки в Одиночной Игре
-- -------------------------------------------------------------------------

-- В Одиночной Игре игрок может тыкнуть по элементу задания и подсмотреть,
-- как он звучит на изучаемом языке. Чем больше подсмотрел — тем меньше
-- награда за раунд: открыл всё — не получил ничего.
--
-- Доля считается по ПЕРВЫМ открытиям и не убывает: перевернув элемент
-- обратно, игрок уже знает ответ, и «вернуть» подсказку нельзя.
alter table training_rounds
  add column if not exists hint_ratio double precision not null default 0
  check (hint_ratio >= 0 and hint_ratio <= 1);

comment on column training_rounds.hint_ratio is
  'Какая доля элементов задания была подсмотрена (0..1). Множитель '
  'награды за раунд — (1 - hint_ratio). ПРИСЫЛАЕТСЯ КЛИЕНТОМ: подсказка '
  'это действие в интерфейсе, которого сервер не видит. Проверить его '
  'сервер сегодня не может, и это осознанный размен — цена вопроса '
  'монеты за один раунд Одиночной Игры.';

-- -------------------------------------------------------------------------
-- Эталон раунда PvP — по языку говорящего
-- -------------------------------------------------------------------------

-- rounds.generated_phrase хранит то, что ПОКАЗАНО в ленте боя, и в Дуэли
-- это две фразы через слэш: игроки переводят на разные языки. Оценить по
-- такой строке нельзя — непонятно, какая половина чья.
--
-- Поэтому эталон для оценки лежит отдельно и по языкам: {"en": "...|...",
-- "ru": "...|..."}. Воркер берёт из неё запись по изучаемому языку
-- говорящего, а generated_phrase остаётся тем, чем был, — текстом для
-- ленты. В Состязании язык у обоих один, и в карте будет один ключ.
--
-- Число элементов во всех языках одинаково (инвариант датасета
-- assets/cefr), поэтому оценка обоих игроков Дуэли идёт по одной и той же
-- шкале, хотя фразы разные.
alter table rounds
  add column if not exists expected_by_language jsonb not null default '{}'::jsonb;

comment on column rounds.expected_by_language is
  'Эталон ответа по языкам: {"<код языка>": "фраза|с|разделителями"}. '
  'По нему считается поэлементная оценка. generated_phrase остаётся '
  'текстом для показа в ленте (в Дуэли — обе фразы через слэш).';

-- -------------------------------------------------------------------------
-- Награда за раунд с учётом подсказок
-- -------------------------------------------------------------------------

/**
 * Начисляет награду за раунд Одиночной Игры. К версии из 0006 добавлен
 * множитель за подсказки.
 *
 * p_hint_ratio = 0 — полная награда (3 монеты за балл, как было);
 * p_hint_ratio = 1 — монет нет вовсе: игрок открыл всю фразу целиком.
 * Округление вниз: открыв почти всё, получаешь 0, а не монету из жалости.
 *
 * ОПЫТ (XP) МНОЖИТЕЛЕМ НЕ РЕЖЕТСЯ. Подсказка — это способ разобраться в
 * непонятном куске, а не способ смухлевать; наказывать за учёбу дважды
 * незачем. Режется только валюта, которая и есть игровая награда.
 *
 * Тело в остальном скопировано из 0006 без изменений: проверка владельца
 * раунда, требование выставленного балла и защита от повторной выдачи
 * через training_round_rewards.
 */
create or replace function public.claim_training_reward(
  p_training_round_id uuid,
  p_hint_ratio double precision default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_score integer;
  v_owner uuid;
  v_coins integer;
  v_ratio double precision := least(1.0, greatest(0.0, coalesce(p_hint_ratio, 0)));
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select tr.final_score, ts.user_id into v_score, v_owner
    from training_rounds tr
    join training_sessions ts on ts.id = tr.session_id
    where tr.id = p_training_round_id
    for update of tr;

  if v_owner is null or v_owner <> v_uid then
    raise exception 'not your training round';
  end if;
  if v_score is null then
    raise exception 'round is not scored yet';
  end if;
  if exists (select 1 from training_round_rewards where training_round_id = p_training_round_id) then
    return jsonb_build_object('already_claimed', true);
  end if;

  v_coins := floor(3 * v_score * (1.0 - v_ratio))::integer;

  -- Доля подсказок хранится в самом раунде, а не только в награде: по ней
  -- потом видно, как игрок проходил уровень, даже если награда не выдана.
  update training_rounds set hint_ratio = v_ratio where id = p_training_round_id;

  insert into training_round_rewards (training_round_id, user_id, coins)
    values (p_training_round_id, v_uid, v_coins);
  if v_coins > 0 then
    update currency_wallets set soft_currency = soft_currency + v_coins where user_id = v_uid;
  end if;
  update users set xp = xp + v_score where id = v_uid;

  return jsonb_build_object('coins', v_coins, 'xp', v_score, 'hint_ratio', v_ratio);
end;
$$;

-- Прежняя одноаргументная версия осталась бы отдельной перегрузкой (в
-- Postgres разная арность — разные функции), и PostgREST выбирал бы её на
-- вызовах без доли подсказок, начисляя полную награду мимо множителя.
drop function if exists public.claim_training_reward(uuid);

grant execute on function public.claim_training_reward(uuid, double precision) to authenticated;
