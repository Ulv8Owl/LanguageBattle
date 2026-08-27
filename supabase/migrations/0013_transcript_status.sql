-- Распознавание речи переехало с устройства на сервер (см.
-- supabase/functions/_shared/transcribeAudio.ts): клиент теперь загружает
-- только аудио, а transcript заполняет воркер evaluate-recording.
--
-- Отдельный столбец нужен потому, что по одному лишь transcript три
-- РАЗНЫХ исхода выглядят одинаково (пустая строка), а игроку про них надо
-- сказать совершенно разное:
--   pending — аудио загружено, воркер ещё не дошёл до распознавания;
--   ok      — речь распознана, transcript непустой;
--   empty   — ASR отработал, но речи не услышал (игрок промолчал/шум) —
--             это честный балл 1;
--   failed  — распознать не удалось по нашей вине (сбой провайдера,
--             таймаут, не настроен ключ) — штрафовать за это игрока нельзя,
--             балл ставится нейтральный.
--
-- Раньше этого различия не было, и тишина показывалась игроку тем же
-- "ОШИБОК НЕ НАЙДЕНО", что и безупречная фраза.

alter table voice_recordings
  add column if not exists transcript_status text not null default 'pending';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'voice_recordings_transcript_status_check'
  ) then
    alter table voice_recordings
      add constraint voice_recordings_transcript_status_check
      check (transcript_status in ('pending','ok','empty','failed'));
  end if;
end $$;

-- Записи, сделанные до перехода на серверный ASR: у них transcript уже
-- финальный (или пустой навсегда — воркер к ним больше не вернётся), так
-- что 'pending' на них означал бы ожидание, которого не будет.
update voice_recordings
set transcript_status = case
  when coalesce(trim(transcript), '') <> '' then 'ok'
  else 'empty'
end
where transcript_status = 'pending';
