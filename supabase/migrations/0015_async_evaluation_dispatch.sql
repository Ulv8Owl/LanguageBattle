-- Задача оценки навсегда застревала в 'processing', а клиент — на экране
-- "Разбираю попытку".
--
-- Причина: у net.http_post в pg_net таймаут по умолчанию 5 СЕКУНД. Пока
-- воркер отвечал за доли секунды (он тогда не делал ни распознавания, ни
-- запроса к LLM — сразу уходил в ветку пустого транскрипта), этого хватало.
-- Теперь он скачивает аудио, ждёт Google STT и подробный разбор от LLM —
-- это заведомо дольше пяти секунд. pg_net обрывал вызов, воркер оставался
-- с задачей в 'processing', и никто её больше не трогал.
--
-- Лечим с двух сторон:
--   1) таймаут вызова поднят до 120 с — с запасом на самый долгий разбор;
--   2) fail_stale_evaluation_jobs() освобождает задачи, зависшие в
--      'processing' (воркер убит платформой, упал контейнер и т.п.), чтобы
--      клиент получил внятный отказ вместо вечного ожидания.
--
-- Сам воркер вдобавок отвечает на вызов сразу и доделывает работу в фоне
-- (EdgeRuntime.waitUntil), так что даже 5-секундный таймаут его больше не
-- обрывал бы — но оставлять здесь заведомо тесный лимит всё равно незачем.

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
    body := jsonb_build_object('job_id', new.id),
    -- Без этого параметра pg_net обрывает вызов через 5 секунд.
    timeout_milliseconds := 120000
  );

  return new;
end;
$$;

-- Идемпотентно: сама функция могла быть пересоздана, триггер — нет.
drop trigger if exists on_evaluation_job_created on evaluation_jobs;
create trigger on_evaluation_job_created
  after insert on evaluation_jobs
  for each row execute function public.trigger_evaluate_recording();

/**
 * Помечает провалившимися задачи, застрявшие в обработке дольше
 * p_stale_seconds. Нужна как страховка: если воркер убит на середине,
 * статус задачи больше никто не изменит, и клиент, ждущий 'done'/'failed'
 * через Realtime, будет ждать вечно.
 *
 * Идемпотентна, безопасна для повторных вызовов, ничего не удаляет.
 */
create or replace function public.fail_stale_evaluation_jobs(p_stale_seconds integer default 180)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update evaluation_jobs
  set status = 'failed',
      completed_at = now()
  where status = 'processing'
    and created_at < now() - make_interval(secs => p_stale_seconds);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.fail_stale_evaluation_jobs(integer) to authenticated;
