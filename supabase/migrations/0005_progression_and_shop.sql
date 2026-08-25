-- Мета-прогрессия и завершение матча (разделы 2.5, 2.6, 6).
--
-- Завершение матча, пересчёт ELO и начисление валюты/опыта нарочно вынесены
-- в security definer RPC, а не в клиентский UPDATE: currency_wallets/users.xp
-- не имеют клиентских insert/update RLS-политик (см. 0002) — награды может
-- начислять только доверенный серверный код, иначе игрок мог бы накрутить
-- себе валюту напрямую через клиент.

alter table users add column if not exists xp integer not null default 0;
alter table users add column if not exists equipped_frame_id uuid references cosmetic_items(id);
alter table users add column if not exists equipped_emote_id uuid references cosmetic_items(id);

-- =========================================================================
-- Каталог косметики (раздел 2.6) — небольшой стартовый набор для Магазина.
-- =========================================================================

insert into cosmetic_items (id, name, type, price_soft, price_hard, rarity) values
  ('11111111-1111-1111-1111-111111111101', 'Золотое кольцо', 'profile_frame', null, 250, 'epic'),
  ('11111111-1111-1111-1111-111111111102', 'Неоновый обод', 'profile_frame', 8, null, 'rare'),
  ('11111111-1111-1111-1111-111111111103', 'Эмоция «Огонь»', 'emote', 90, null, 'common'),
  ('11111111-1111-1111-1111-111111111104', 'Эмоция «GG»', 'emote', 60, null, 'common')
on conflict (id) do nothing;

-- =========================================================================
-- finalize_match — считает победителя, ELO, валюту и опыт по факту того,
-- что реально лежит в round_scores (не доверяет клиенту).
-- =========================================================================

create or replace function public.finalize_match(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match matches%rowtype;
  v_total_a integer := 0;
  v_total_b integer := 0;
  v_round_count integer;
  v_scored_rounds integer;
  v_winner uuid;
  v_lang_a text;
  v_lang_b text;
  v_elo_a integer;
  v_elo_b integer;
  v_k_a integer;
  v_k_b integer;
  v_expected_a numeric;
  v_actual_a numeric;
  v_change_a integer := 0;
  v_change_b integer := 0;
  v_matches_a integer;
  v_matches_b integer;
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

  select coalesce(sum(score), 0) into v_total_a
    from round_scores s join rounds r on r.id = s.round_id
    where r.match_id = p_match_id and s.user_id = v_match.player_a_id;
  select coalesce(sum(score), 0) into v_total_b
    from round_scores s join rounds r on r.id = s.round_id
    where r.match_id = p_match_id and s.user_id = v_match.player_b_id;

  if v_total_a > v_total_b then
    v_winner := v_match.player_a_id;
  elsif v_total_b > v_total_a then
    v_winner := v_match.player_b_id;
  else
    v_winner := null;
  end if;

  -- ELO пересчитывается только для настоящего PvP (не против бота).
  if not v_match.is_bot_opponent then
    if v_match.game_mode = 'native_duel' then
      v_lang_a := split_part(v_match.language_pair, '-', 2); -- целевой для A = родной B
      v_lang_b := split_part(v_match.language_pair, '-', 1); -- целевой для B = родной A
    else
      v_lang_a := v_match.language_pair;
      v_lang_b := v_match.language_pair;
    end if;

    select elo into v_elo_a from user_languages
      where user_id = v_match.player_a_id and language_code = v_lang_a and role = 'learning' limit 1;
    select elo into v_elo_b from user_languages
      where user_id = v_match.player_b_id and language_code = v_lang_b and role = 'learning' limit 1;

    if v_elo_a is not null and v_elo_b is not null then
      select count(*) into v_matches_a from matches
        where status = 'completed' and not is_bot_opponent and (player_a_id = v_match.player_a_id or player_b_id = v_match.player_a_id);
      select count(*) into v_matches_b from matches
        where status = 'completed' and not is_bot_opponent and (player_a_id = v_match.player_b_id or player_b_id = v_match.player_b_id);
      v_k_a := case when v_matches_a < 30 then 32 else 16 end;
      v_k_b := case when v_matches_b < 30 then 32 else 16 end;

      v_expected_a := 1.0 / (1.0 + power(10.0, (v_elo_b - v_elo_a) / 400.0));
      v_actual_a := case when v_winner = v_match.player_a_id then 1.0
                          when v_winner is null then 0.5
                          else 0.0 end;

      v_change_a := round(v_k_a * (v_actual_a - v_expected_a));
      v_change_b := round(v_k_b * ((1.0 - v_actual_a) - (1.0 - v_expected_a)));

      update user_languages set elo = elo + v_change_a
        where user_id = v_match.player_a_id and language_code = v_lang_a and role = 'learning';
      update user_languages set elo = elo + v_change_b
        where user_id = v_match.player_b_id and language_code = v_lang_b and role = 'learning';
    end if;
  end if;

  update matches set
    status = 'completed',
    winner_id = v_winner,
    elo_change_a = v_change_a,
    elo_change_b = v_change_b,
    completed_at = now()
  where id = p_match_id;

  -- Валюта/опыт за участие + бонус победителю (раздел 2.5).
  update currency_wallets set soft_currency = soft_currency + 50 where user_id = v_match.player_a_id;
  update currency_wallets set soft_currency = soft_currency + 50 where user_id = v_match.player_b_id;
  update users set xp = xp + 20 where id = v_match.player_a_id;
  update users set xp = xp + 20 where id = v_match.player_b_id;
  if v_winner is not null then
    update currency_wallets set soft_currency = soft_currency + 50 where user_id = v_winner;
    update users set xp = xp + 30 where id = v_winner;
  end if;

  return jsonb_build_object(
    'winner_id', v_winner,
    'total_a', v_total_a,
    'total_b', v_total_b,
    'elo_change_a', v_change_a,
    'elo_change_b', v_change_b
  );
end;
$$;

grant execute on function public.finalize_match(uuid) to authenticated;

-- =========================================================================
-- purchase_item / equip_item — магазин (раздел 2.6). currency_wallets и
-- user_inventory остаются без клиентских insert/update policies — только
-- через эти RPC.
-- =========================================================================

create or replace function public.purchase_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item cosmetic_items%rowtype;
  v_wallet currency_wallets%rowtype;
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from user_inventory where user_id = v_uid and item_id = p_item_id) then
    raise exception 'item already owned';
  end if;

  select * into v_item from cosmetic_items where id = p_item_id;
  if not found then
    raise exception 'item % not found', p_item_id;
  end if;

  select * into v_wallet from currency_wallets where user_id = v_uid for update;
  if not found then
    raise exception 'wallet not found for current user';
  end if;

  if v_item.price_soft is not null and v_wallet.soft_currency >= v_item.price_soft then
    update currency_wallets set soft_currency = soft_currency - v_item.price_soft where user_id = v_uid;
  elsif v_item.price_hard is not null and v_wallet.hard_currency >= v_item.price_hard then
    update currency_wallets set hard_currency = hard_currency - v_item.price_hard where user_id = v_uid;
  else
    raise exception 'insufficient funds';
  end if;

  insert into user_inventory (user_id, item_id) values (v_uid, p_item_id)
    on conflict (user_id, item_id) do nothing;
end;
$$;

grant execute on function public.purchase_item(uuid) to authenticated;

create or replace function public.equip_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item cosmetic_items%rowtype;
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if not exists (select 1 from user_inventory where user_id = v_uid and item_id = p_item_id) then
    raise exception 'item not owned';
  end if;

  select * into v_item from cosmetic_items where id = p_item_id;
  if not found then
    raise exception 'item % not found', p_item_id;
  end if;

  if v_item.type = 'profile_frame' then
    update users set equipped_frame_id = p_item_id where id = v_uid;
  elsif v_item.type = 'emote' then
    update users set equipped_emote_id = p_item_id where id = v_uid;
  else
    raise exception 'item type % is not equippable yet', v_item.type;
  end if;
end;
$$;

grant execute on function public.equip_item(uuid) to authenticated;
