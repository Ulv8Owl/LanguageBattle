-- =========================================================================
-- ГОСТЕВОЙ ВХОД И ВХОД ПО НИКУ
-- =========================================================================
--
-- ПОЧЕМУ ИГРОК НАЧИНАЕТ БЕЗ РЕГИСТРАЦИИ. Форма входа на первом экране —
-- это счёт, выставленный до того, как показали товар. Duolingo спрашивает
-- почту после первого урока, и у нас теперь так же: «Начать» заводит
-- анонимный аккаунт Supabase, и всё, что игрок дальше выберет — языки,
-- уровень, рейтинг, серия, — сразу принадлежит ЕМУ. Короткая регистрация
-- потом не создаёт новый аккаунт, а достраивает этот: ничего не теряется.
--
-- ЧТО ТАКОЕ «АНОНИМНЫЙ» ЗДЕСЬ. Обычная строка в auth.users с
-- is_anonymous = true. Для RLS он такой же authenticated, все политики по
-- auth.uid() работают без изменений. Включается это НЕ миграцией, а
-- галкой в панели Supabase (Authentication → Sign In / Providers →
-- Anonymous sign-ins) — без неё «Начать» будет отвечать отказом.
--
-- ПОЧЕМУ У ВСЕХ ЕСТЬ ПОЧТА, ДАЖЕ У ТЕХ, КТО ЕЁ НЕ ДАВАЛ. Supabase умеет
-- пароль только в паре с почтой или телефоном. Игрок, отказавшийся от
-- почты, всё равно должен уметь войти по нику и паролю — поэтому ему
-- выдаётся служебный адрес вида <id>@guest.chrolingo.app. Письма туда
-- никто не шлёт и слать не может: подтверждение почты выключено.

-- -------------------------------------------------------------------------
-- 1. Ник уникален без оглядки на регистр
-- -------------------------------------------------------------------------

-- «Chrolingo» и «chrolingo» — один и тот же ник для человека и два
-- разных для базы. Обычного unique мало: игрок зарегистрирует второй и
-- будет уверен, что это его первый.
create unique index if not exists users_username_lower_key
  on public.users (lower(username));

-- -------------------------------------------------------------------------
-- 2. Занять ник
-- -------------------------------------------------------------------------

-- ЧЕРЕЗ RPC, А НЕ ОБНОВЛЕНИЕМ СТРОКИ. Клиент, пишущий username напрямую,
-- получает на занятом нике сырую ошибку Postgres про индекс — её нельзя
-- показать игроку. Здесь ошибки названы словами, которые экран умеет
-- перевести.
create or replace function public.claim_username(p_username text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := trim(coalesce(p_username, ''));
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if length(v_name) < 3 or length(v_name) > 20 then
    raise exception 'username_length';
  end if;
  -- Пробелы и знаки препинания запрещены не ради строгости: ник виден в
  -- чужих списках, и «  Игрок  » от «Игрок» там не отличить.
  if v_name !~ '^[A-Za-z0-9А-Яа-яЁё_-]+$' then
    raise exception 'username_invalid';
  end if;
  if exists (
    select 1 from public.users
    where lower(username) = lower(v_name) and id <> v_uid
  ) then
    raise exception 'username_taken';
  end if;

  update public.users set username = v_name where id = v_uid;
  return v_name;
end;
$$;

grant execute on function public.claim_username(text) to authenticated;

-- Имя гостю. Он попадает в чужие списки (Арена показывает соперника), и
-- пустое место там читается как сбой, а не как «человек не представился».
create or replace function public.ensure_guest_name()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_name text;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  select username into v_name from public.users where id = v_uid;
  if v_name is not null and length(v_name) > 0 then
    return v_name;
  end if;
  -- Шесть знаков из собственного id: не повторяется и ничего о человеке
  -- не рассказывает.
  v_name := 'Гость-' || upper(substr(replace(v_uid::text, '-', ''), 1, 6));
  update public.users set username = v_name where id = v_uid;
  return v_name;
end;
$$;

grant execute on function public.ensure_guest_name() to authenticated;

-- -------------------------------------------------------------------------
-- 3. Вход по нику
-- -------------------------------------------------------------------------

-- ОТДАЁТ ПОЧТУ ПО НИКУ — И ПОТОМУ ЗАКРЫТА ОТ ИГРОКОВ. Ники видны всем
-- (Арена, друзья, рейтинг), и функция, доступная клиенту, превратила бы
-- список ников в список почтовых адресов. Звать её может только
-- service_role, то есть Edge Function `login`, которая ничего наружу не
-- отдаёт, кроме сессии, и только при верном пароле.
--
-- Тот же приём, что у spend_energy: право на вызов — часть защиты.
create or replace function public.resolve_login_email(p_login text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_login text := trim(coalesce(p_login, ''));
  v_email text;
begin
  if v_login = '' then
    return null;
  end if;
  -- Похоже на почту — она и есть: искать такой ник незачем.
  if position('@' in v_login) > 0 then
    return lower(v_login);
  end if;
  select au.email into v_email
  from public.users u
  join auth.users au on au.id = u.id
  where lower(u.username) = lower(v_login);
  return v_email;
end;
$$;

revoke all on function public.resolve_login_email(text) from public, anon, authenticated;
grant execute on function public.resolve_login_email(text) to service_role;

-- -------------------------------------------------------------------------
-- 4. Кто уже не гость
-- -------------------------------------------------------------------------

-- Признак «аккаунт достроен» нужен и экранам, и будущим проверкам на
-- сервере. Считаем достроенным того, у кого есть пароль: почта может
-- быть служебной, ник — гостевым, а пароль ставят только руками.
create or replace function public.account_is_registered()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select not au.is_anonymous
     from auth.users au
     where au.id = auth.uid()),
    false
  )
$$;

grant execute on function public.account_is_registered() to authenticated;
