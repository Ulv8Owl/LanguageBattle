-- =========================================================================
-- Энергия восстанавливается по секундам, а не по четверти часа.
--
-- ЧТО БЫЛО. Одна единица за 15 минут — то есть полный запас в 50 копился
-- больше двенадцати часов. Для игры это осмысленно, для проверки режима —
-- нет: один разбор записи стоит восемь единиц, и после двух неудачных
-- попыток день кончался. По прямой просьбе владельца шаг переводится на
-- 10 секунд (одна единица за 10 с, полный запас примерно за 8 минут).
--
-- СЧИТАЕМ В СЕКУНДАХ, А НЕ В МИНУТАХ. Прежняя формула брала целые минуты и
-- делила их на 15; при шаге в 10 секунд деление минут дало бы ноль всегда, и
-- энергия не восстанавливалась бы вовсе.
--
-- ОСТАТОК НЕ СГОРАЕТ — как и раньше: точка отсчёта сдвигается ровно на
-- начисленное, а не на now(). Иначе частые проверки кошелька обнуляли бы
-- недосчитанное время, и чем чаще игрок заходит, тем медленнее копилось бы.
-- =========================================================================

create or replace function public.regen_energy(p_user_id uuid)
returns currency_wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wallet currency_wallets%rowtype;
  v_step_seconds constant integer := 10;
  v_seconds integer;
  v_gained integer;
begin
  select * into v_wallet from currency_wallets where user_id = p_user_id for update;
  if not found then
    raise exception 'wallet not found for user %', p_user_id;
  end if;

  if v_wallet.energy_current >= v_wallet.energy_max then
    -- Полный запас: сдвигаем точку отсчёта, чтобы простой не копился.
    update currency_wallets set energy_last_regen_at = now()
      where user_id = p_user_id returning * into v_wallet;
    return v_wallet;
  end if;

  v_seconds := floor(extract(epoch from (now() - v_wallet.energy_last_regen_at)))::integer;
  v_gained := v_seconds / v_step_seconds;
  if v_gained <= 0 then
    return v_wallet;
  end if;

  update currency_wallets set
    energy_current = least(energy_max, energy_current + v_gained),
    -- Остаток секунд не сгорает: переносим его в новую точку отсчёта.
    energy_last_regen_at = energy_last_regen_at + make_interval(secs => v_gained * v_step_seconds)
  where user_id = p_user_id
  returning * into v_wallet;

  return v_wallet;
end;
$$;

comment on function public.regen_energy(uuid) is
  'Досчитывает восстановленную энергию: одна единица за каждые 10 секунд '
  'простоя, не выше потолка. Остаток времени переносится, а не сгорает.';
