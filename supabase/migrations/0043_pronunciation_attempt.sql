-- Вторая попытка Одиночной Игры проверяет ПРОИЗНОШЕНИЕ, а не перевод.
--
-- ЧТО БЫЛО НЕ ТАК. Обе попытки раунда были одной и той же проверкой
-- перевода. Игрок делал первую, читал разбор с правильным вариантом — и
-- повторял его во второй. Балл ставился по второй, то есть по тому, что
-- ему только что показали: проверялась память на одну фразу, а не язык.
--
-- Теперь перевод оценивается один раз, по первой попытке, а вторая слушает
-- только звук. Это две разные проверки с разными баллами, и раунд
-- заканчивается итогом из двух чисел.

-- Роль записи. ОТДЕЛЬНАЯ КОЛОНКА, А НЕ НОМЕР ПОПЫТКИ: раньше роль выводили
-- из attempt_number, и проверка уровня присылала «попытку 2» при
-- единственной попытке в раунде — просто чтобы воркер поставил балл.
-- Ролей стало две, и вывести обе из одного числа больше нельзя.
alter table voice_recordings
  add column if not exists judge_mode text not null default 'translation';

alter table voice_recordings drop constraint if exists voice_recordings_judge_mode_check;
alter table voice_recordings
  add constraint voice_recordings_judge_mode_check
  check (judge_mode in ('translation', 'pronunciation'));

comment on column voice_recordings.judge_mode is
  'Что проверяет эта запись: translation — перевод (лента разбора, ошибки '
  'по смыслу), pronunciation — только звук (расшифровки нет вовсе, ошибки '
  'по словам). Ставит клиент: роль записи известна ему в момент отправки.';

-- Балл за произношение — рядом с баллом за перевод, а не вместо него.
alter table training_rounds
  add column if not exists pronunciation_score integer
  check (pronunciation_score between 1 and 10);

comment on column training_rounds.pronunciation_score is
  'Балл за произношение (вторая попытка). final_score теперь — балл за '
  'ПЕРЕВОД по первой попытке. Раньше final_score ставился по второй, то '
  'есть по фразе, которую игрок только что прочитал в разборе.';

comment on column training_rounds.final_score is
  'Балл за ПЕРЕВОД — по первой попытке раунда (на проверке уровня по '
  'единственной). Балл за произношение лежит в pronunciation_score.';

-- Ошибки произношения — своя категория: разбор перевода и разбор звука
-- показываются в разных блоках, и различать их по тексту было бы гаданием.
alter table grammar_errors drop constraint if exists grammar_errors_category_check;
alter table grammar_errors
  add constraint grammar_errors_category_check
  check (category in ('grammar', 'spelling', 'style', 'element', 'omni', 'pronunciation'));

comment on column grammar_errors.category is
  'omni — ошибка перевода от мультимодальной модели (span_text — фрагмент '
  'речи игрока). pronunciation — ошибка произношения (span_text — слово, '
  'которое прозвучало не так). Остальные значения остались от прежних '
  'механик и в новых записях не появляются.';
