-- Подключает реальный ИИ-пайплайн (Фаза 2): каждая новая строка в
-- evaluation_jobs асинхронно дёргает Edge Function evaluate-recording
-- через pg_net (см. раздел 9.8 — клиент никогда не ждёт ASR/LLM
-- синхронно, здесь то же самое на уровне БД).
--
-- ВАЖНО: секреты (URL функции и service_role key) НЕ хранятся в этом
-- файле — они кладутся в Supabase Vault отдельной командой ПОСЛЕ
-- применения миграции (см. supabase/README.md), чтобы не попадать в git.
-- Пока секреты не заданы, триггер просто ничего не делает (WARNING в
-- логах) — это безопасное поведение "as if Фаза 2 ещё не подключена".

create extension if not exists pg_net;

create or replace function public.trigger_evaluate_recording()
returns trigger
language plpgsql
security definer
set search_path = public, vault, net
as $$
declare
  v_url text;
  v_service_key text;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'evaluate_recording_url';
  select decrypted_secret into v_service_key
    from vault.decrypted_secrets where name = 'service_role_key';

  if v_url is null or v_service_key is null then
    raise warning 'evaluate_recording_url/service_role_key not set in Vault — skipping AI evaluation for job %', new.id;
    return new;
  end if;

  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_key
    ),
    body := jsonb_build_object('job_id', new.id)
  );

  return new;
end;
$$;

drop trigger if exists on_evaluation_job_created on evaluation_jobs;
create trigger on_evaluation_job_created
  after insert on evaluation_jobs
  for each row execute function public.trigger_evaluate_recording();
