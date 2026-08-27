-- service_role (используется ТОЛЬКО Edge Function'ами через
-- SUPABASE_SERVICE_ROLE_KEY, никогда клиентом) имел rolbypassrls=true, но
-- это обходит только RLS-политики — не заменяет обычный GRANT на объекты.
-- Ни одна миграция ни разу не выдавала service_role права на таблицы (везде
-- грант шёл только на authenticated), поэтому evaluate-recording падал с
-- "permission denied for table evaluation_jobs" (42501) на самом первом же
-- select — и упал бы точно так же на voice_recordings/users/training_rounds
-- и любой другой таблице, до которой дошло бы дело.
--
-- alter default privileges — чтобы будущие таблицы (в новых миграциях)
-- не наступали на те же грабли автоматически.

grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all functions in schema public to service_role;

alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant all on functions to service_role;
