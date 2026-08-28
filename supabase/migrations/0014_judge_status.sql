-- Сбой LLM-судьи выглядел для игрока ровно как безупречный ответ.
--
-- Когда модель не отвечала (или отвечала не тем форматом), evaluateGrammar
-- возвращал degraded=true с ПУСТЫМ списком ошибок. Клиент же видел только
-- grammar_errors, а пустой список он трактует единственным образом —
-- "ОШИБОК НЕ НАЙДЕНО". То есть неработающий судья был неотличим от
-- работающего судьи, не нашедшего ошибок: ровно та же ловушка, что была с
-- распознаванием речи до миграции 0013.
--
--   pending  — задача ещё не дошла до судьи;
--   ok       — судья ответил, список ошибок настоящий (пустой = ошибок нет);
--   degraded — судья не ответил/ответил мусором, балл нейтральный;
--   skipped  — судью не звали: речь не распознана или это родной слот Дуэли.

alter table voice_recordings
  add column if not exists judge_status text not null default 'pending';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'voice_recordings_judge_status_check'
  ) then
    alter table voice_recordings
      add constraint voice_recordings_judge_status_check
      check (judge_status in ('pending','ok','degraded','skipped'));
  end if;
end $$;

-- Записи, оценённые до появления столбца: судья по ним уже отработал и
-- больше не вернётся, так что 'pending' означал бы ожидание, которого не
-- будет. Различить ok/degraded задним числом невозможно — помечаем как ok,
-- потому что для уже показанных игроку раундов это ничего не меняет.
update voice_recordings
set judge_status = 'ok'
where judge_status = 'pending'
  and id in (select voice_recording_id from evaluation_jobs where status in ('done','failed'));
