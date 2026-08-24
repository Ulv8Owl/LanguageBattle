-- Явные GRANT для роли authenticated. RLS-политики (0002) решают, какие
-- именно строки видно/можно менять, но это работает только поверх базового
-- табличного GRANT — без него Postgres блокирует запрос ещё до применения
-- политик, с ошибкой "permission denied for table ...". На новых Supabase-
-- проектах это обычно настроено через default privileges автоматически,
-- но если по какой-то причине не подхватилось (частичные прогоны, ручные
-- правки через Table Editor и т.п.) — этот файл чинит ситуацию явно и
-- безопасно (повторный прогон — no-op, ошибок не даёт).

grant usage on schema public to authenticated;

grant select, insert, update, delete on all tables in schema public to authenticated;

-- На случай будущих миграций, добавляющих новые таблицы — грант применится
-- к ним автоматически, без необходимости снова вспоминать про этот файл.
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
