-- Chrolingo — срочный фикс бага и правки по итогам первого реального теста
-- на телефоне (скриншот "Не удалось загрузить друзей: ... infinite
-- recursion detected in policy for relation \"party_members\"").
--
-- Также: сокращение пробного периода до 1 суток (было 7 дней) — новым
-- умолчанием для будущих регистраций, ретроактивно подрезаны и уже
-- существующие 'trial'-подписки.

-- =========================================================================
-- 1. БАГ: infinite recursion в RLS-политике party_members.
--
-- Политика "party_members: co-members can view" (0006) делала
-- self-referencing exists (select ... from party_members ...) внутри
-- политики САМОЙ party_members — Postgres пересчитывает политику для
-- каждой строки внутреннего запроса, и внутренний запрос снова упирается
-- в ту же политику. Бесконечная рекурсия.
--
-- Фикс — стандартный для Supabase: вынести проверку членства в
-- SECURITY DEFINER функцию. Такая функция выполняется с правами
-- владельца (в миграциях это подключение, применяющее их, обычно с
-- правами, для которых RLS на party_members не действует), поэтому
-- внутренний select не проходит через политику повторно.
-- =========================================================================

create or replace function public.my_party_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select party_id from party_members where user_id = auth.uid() limit 1;
$$;

grant execute on function public.my_party_id() to authenticated;

drop policy if exists "party_members: co-members can view" on party_members;
create policy "party_members: co-members can view"
  on party_members for select
  to authenticated
  using (
    user_id = auth.uid()
    or party_id = public.my_party_id()
  );

-- =========================================================================
-- 2. Пробный период: 7 дней -> 1 сутки.
-- =========================================================================

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id) values (new.id);
  insert into public.currency_wallets (user_id) values (new.id);
  insert into public.subscriptions (user_id, status, trial_ends_at)
    values (new.id, 'trial', now() + interval '1 day');
  return new;
end;
$$;

-- Уже выданные пробные периоды подрезаются до 1 суток от даты регистрации
-- (только вниз — если у кого-то уже осталось меньше суток, не продлеваем).
update subscriptions s set trial_ends_at = least(
  s.trial_ends_at,
  (select u.created_at from users u where u.id = s.user_id) + interval '1 day'
)
where s.status = 'trial';

grant select, insert, update, delete on all tables in schema public to authenticated;
