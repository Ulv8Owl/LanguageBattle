-- Своё голосовое можно перезаписать.
--
-- ЧТО БЫЛО СЛОМАНО. На бакете voice-recordings стояли только политики на
-- чтение и на ВСТАВКУ. Загрузка идёт с upsert: true — то есть попадание в
-- уже существующий объект Storage считает обновлением, а политики на
-- обновление не было вовсе. Игрок получал 403 «new row violates row-level
-- security policy» и больше ничего записать не мог.
--
-- Вылезло это, когда в Одиночной Игре появился повтор ответа: раунд, в
-- котором нечего было разбирать, не закрывается баллом, игрок говорит
-- заново — и вторая запись шла по тому же пути, что и первая.
--
-- Клиент теперь и так даёт каждой отправке своё имя, но политика всё равно
-- нужна: upsert: true стоит во ВСЕХ загрузках, и без неё этот флаг молча
-- работает только на новых объектах. Флаг, который делает не то, что
-- написано, — это следующая такая же ошибка, просто ещё не найденная.
--
-- Условие ровно то же, что у вставки: свой раунд боя или своя сессия соло.
-- Ни на байт шире.
drop policy if exists "voice-recordings: participants can overwrite" on storage.objects;
create policy "voice-recordings: participants can overwrite"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'voice-recordings'
    and (
      (
        (storage.foldername(name))[1] = 'match'
        and exists (
          select 1 from matches m
          where m.id::text = (storage.foldername(name))[2]
            and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
        )
      )
      or (
        (storage.foldername(name))[1] = 'training'
        and exists (
          select 1 from training_sessions ts
          where ts.id::text = (storage.foldername(name))[2]
            and ts.user_id = auth.uid()
        )
      )
    )
  )
  with check (
    bucket_id = 'voice-recordings'
    and (
      (
        (storage.foldername(name))[1] = 'match'
        and exists (
          select 1 from matches m
          where m.id::text = (storage.foldername(name))[2]
            and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
        )
      )
      or (
        (storage.foldername(name))[1] = 'training'
        and exists (
          select 1 from training_sessions ts
          where ts.id::text = (storage.foldername(name))[2]
            and ts.user_id = auth.uid()
        )
      )
    )
  );
