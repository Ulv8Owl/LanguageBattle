-- =========================================================================
-- «Аудирование»: запись игрока можно положить в хранилище на время разбора.
--
-- ЧТО БЫЛО СЛОМАНО. Бакет voice-recordings знал ровно два вида путей —
-- match/{match_id}/… и training/{session_id}/…, — и все четыре политики
-- (чтение, вставка, обновление, удаление) перечисляли их поимённо. Разбор
-- записи кладёт файл ТРЕТЬИМ путём, tracks/{user_id}/{track_id}.{ext}, и
-- под этот путь не подходила ни одна политика. Игрок получал
--
--     StorageException(message: new row violates row-level security policy,
--                      statusCode: 403, error: Unauthorized)
--
-- то есть отказ ровно на первом шаге, ещё до модели и до списания энергии.
--
-- ПОЧЕМУ ЭТО НЕ ЗАМЕТИЛИ РАНЬШЕ. Путь проверяется в двух местах, и оба
-- выглядели согласованными: клиент собирает tracks/{user_id}/…, функция
-- transcribe-track отказывает, если путь начинается иначе. Но право ПИСАТЬ
-- по этому пути живёт в третьем месте — в политиках хранилища, — и его
-- никто не выдавал. Согласованность двух мест из трёх и выглядит как
-- работающая функция ровно до живого запуска.
--
-- УСЛОВИЕ УЖЕ, ЧЕМ У СОСЕДЕЙ, И ЭТО НАМЕРЕННО. Матч и Одиночная спрашивают
-- базу, участник ли игрок; здесь спрашивать нечего — это личный файл
-- игрока, и принадлежность видна прямо в пути. Поэтому условие одно:
-- вторая папка обязана быть его собственным user_id. Чужую папку не
-- открывает ни одна из четырёх политик.
--
-- ЧИТАТЬ ЗАПИСЬ ИГРОКУ НЕ НУЖНО — он играет файл с телефона, а не из
-- хранилища; провайдеру её отдаёт функция asr-audio под серверным ключом.
-- Политика на чтение всё же есть, и вот почему: загрузка идёт с
-- upsert: true, а этот путь в Storage начинается с поиска существующего
-- объекта. Без права его увидеть upsert повторной загрузки превращается во
-- вставку поверх существующей строки — то есть в отказ, объяснить который
-- по тексту ошибки невозможно. Читать при этом игрок может ровно свою
-- папку, то есть ровно то, что сам туда и положил.
-- =========================================================================

create or replace function public.own_listening_track(name text)
returns boolean
language sql
-- STABLE, а не IMMUTABLE: внутри auth.uid(), а он читает claims запроса.
-- Обещав планировщику неизменность, мы разрешили бы ему вычислить это один
-- раз и применить к другому запросу — то есть к другому игроку.
stable
-- SECURITY INVOKER (по умолчанию) здесь обязателен: auth.uid() должен
-- вернуть того, кто пришёл, а не того, кто создал функцию.
set search_path = public
as $$
  select (storage.foldername(name))[1] = 'tracks'
     and (storage.foldername(name))[2] = auth.uid()::text;
$$;

comment on function public.own_listening_track(text) is
  'Путь в бакете voice-recordings ведёт в папку «Аудирования» этого игрока: '
  'tracks/{его user_id}/… . Одно условие на все четыре политики — '
  'разъехавшись, они дали бы право писать туда, откуда нельзя удалить.';

drop policy if exists "voice-recordings: own listening track read" on storage.objects;
create policy "voice-recordings: own listening track read"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'voice-recordings' and public.own_listening_track(name));

drop policy if exists "voice-recordings: own listening track upload" on storage.objects;
create policy "voice-recordings: own listening track upload"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'voice-recordings' and public.own_listening_track(name));

-- Загрузка идёт с upsert: true. Попадание в уже существующий объект
-- Storage считает ОБНОВЛЕНИЕМ, и без этой политики повторный разбор той же
-- записи отказывал бы тем же 403 — ровно та же ловушка, что уже разбиралась
-- в 0045 для боевых записей.
drop policy if exists "voice-recordings: own listening track overwrite" on storage.objects;
create policy "voice-recordings: own listening track overwrite"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'voice-recordings' and public.own_listening_track(name))
  with check (bucket_id = 'voice-recordings' and public.own_listening_track(name));

-- Копия живёт ровно столько, сколько идёт разбор: клиент удаляет её сразу
-- после ответа, включая случай отказа. Без права на удаление она осталась
-- бы у нас навсегда — то есть чужая фонотека на нашем сервере.
drop policy if exists "voice-recordings: own listening track delete" on storage.objects;
create policy "voice-recordings: own listening track delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'voice-recordings' and public.own_listening_track(name));
