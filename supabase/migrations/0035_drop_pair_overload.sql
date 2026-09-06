-- Снять перегрузку set_active_language_pair.
--
-- ЧТО СЛОМАЛОСЬ. Миграция 0034 добавила функции второй параметр через
-- `create or replace function set_active_language_pair(text, text default
-- null)`. Postgres различает функции по СИГНАТУРЕ, а не по имени: это не
-- заменило прежнюю однопараметрическую версию из 0009, а создало рядом
-- вторую. С этого момента вызов с одним p_target_language стал
-- неоднозначным, и PostgREST отвечал на него отказом:
--
--   PGRST203: Could not choose the best candidate function between:
--   set_active_language_pair(p_target_language => text),
--   set_active_language_pair(p_target_language => text,
--                            p_native_language => text)
--
-- То есть переключение пары перестало работать вообще — и у клиентов,
-- которые ещё шлют один аргумент, и у любого, кто попадёт на эту
-- неоднозначность.
--
-- ОБИДНО ТО, что ровно эта ловушка описана в 0025 для add_language_pair, и
-- там она обойдена явным drop. Здесь я её повторил. Значение по умолчанию
-- у второго параметра создаёт иллюзию, будто старый вызов «всё ещё
-- поддерживается»: поддерживается он ровно до тех пор, пока рядом нет
-- второй функции, которая тоже готова его принять.
--
-- Явный drop оставляет ровно одну функцию. Вызов с одним аргументом снова
-- однозначен — второй параметр подставится по умолчанию.

drop function if exists public.set_active_language_pair(text);

-- Права переносим на оставшуюся сигнатуру: drop унёс с собой и грант,
-- выданный удалённой версии.
grant execute on function public.set_active_language_pair(text, text) to authenticated;
