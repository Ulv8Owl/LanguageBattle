import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Раунд Одиночной Игры — ОДНА часть: задание, ответ, разбор, балл.
///
/// Сначала попыток было две, и обе проверяли перевод: игрок делал первую,
/// читал разбор с правильным вариантом — и повторял его во второй. Балл
/// ставился по второй, то есть по тому, что ему только что показали.
/// Потом вторую сделали проверкой произношения, а затем убрали и её.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String judge() => read('supabase/functions/_shared/review.ts');
  String prompt() => read('supabase/functions/_shared/prompts/judgeText.ts');
  String worker() => read('supabase/functions/evaluate-recording/index.ts');
  String screen() => read('lib/features/training/training_screen.dart');
  String review() => read('lib/widgets/round_review.dart');
  String migration() => read('supabase/migrations/0043_one_part_round.sql');

  group('произношения в проекте не осталось', () {
    test('ни в промптах, ни в воркере, ни на экране', () {
      for (final source in {
        'review.ts': judge(),
        'evaluate-recording': worker(),
        'training_screen.dart': screen(),
        'voice_submission.dart': read('lib/data/voice_submission.dart'),
      }.entries) {
        expect(source.value.toLowerCase().contains('pronunc'), isFalse,
            reason: source.key);
        // Единственное уцелевшее упоминание — объяснение, ЗАЧЕМ модель
        // слушает звук вместо расшифровки. Это про разбор перевода.
        final mentions = 'произношени'.allMatches(source.value).length;
        // Единственное уцелевшее упоминание — в воркере, где сказано, чем
        // платим за дешевизну двух шагов: судья не слышит произношения.
        expect(mentions, lessThanOrEqualTo(source.key == 'evaluate-recording' ? 1 : 0),
            reason: source.key);
      }
    });

    test('колонки убраны, а категории ошибок не тронуты', () {
      final sql = migration();
      // Через `if exists`: прежняя версия миграции падала на CHECK и
      // откатывалась целиком, так что колонок могло и не появиться.
      expect(sql, contains('alter table voice_recordings drop column if exists judge_mode;'));
      expect(sql, contains('alter table training_rounds drop column if exists pronunciation_score;'));
      // Список категорий не сужается: строки с прежними значениями лежат
      // в базе, и CHECK, который их запрещает, роняет миграцию.
      expect(sql.contains('check (category in'), isFalse);
    });
  });

  group('раунд соло', () {
    test('попытка одна — и в игре, и на проверке уровня', () {
      final s = screen();
      expect(s, contains('const attempt = 1;'));
      // Этапов «первая/вторая» больше нет.
      expect(s.contains('awaitingSecond'), isFalse);
      expect(s.contains('gradingSecond'), isFalse);
      expect(s, contains('awaitingAnswer'));
    });

    test('разбор и балл приходят одним ответом модели', () {
      final s = screen();
      // Ждём одну вещь — статус задачи. Балл воркер пишет до того, как
      // закрыть задачу, поэтому второй подписки не нужно.
      expect(s, contains('void _watchRound(String roundId, String recordingId)'));
      expect(s.contains('_watchFinalScore'), isFalse);
    });

    test('балл за раунд ставит воркер по единственной записи', () {
      final s = worker();
      expect(s, contains('.update({ final_score: score })'));
      expect(s.contains('if (attemptNumber >= 2) {'), isFalse);
    });
  });

  group('«ошибок не найдено» — только когда сказано целиком', () {
    test('заголовок разбора смотрит на пропуски', () {
      // Игрок сказал одно предложение из двух без ошибок в сказанном и
      // видел «ОШИБОК НЕ НАЙДЕНО» над красным пропуском и баллом 5.
      final s = screen();
      // Списка ошибок на этой ветке нет, поэтому заголовок решается по
      // ленте — и проверять одно лишь несказанное мало в обе стороны:
      // лишнее слово даёт зачёркнутый кусок без красного рядом.
      expect(s, contains('_ when _flawless =>'));
      expect(s, contains("(attempt?.reviewSpans ?? const []).every((s) => s.kind == 'ok')"));
    });

    test('серых подписей под лентой не осталось вовсе', () {
      // Плашка теперь — сам красный текст, а подписи говорили о ленте то,
      // что лента и так показывает.
      final s = review();
      // Проверяем СТРОКУ КОДА, а не упоминание: в комментарии рядом
      // объяснено, почему подписи убраны, и это не то же самое.
      expect(s.contains("'Ошибок не найдено"), isFalse);
      expect(s.contains("'фраза сказана не целиком"), isFalse);
      // Заголовок разбора решается по ленте: ни красного, ни зачёркнутого.
      expect(read('lib/features/training/training_screen.dart'),
          contains("bool get _flawless =>"));
    });
  });

  group('промпт разбора', () {
    test('самоисправление не считается ошибкой', () {
      // Самоисправления судья здесь не видит: запись до него не доезжает, а
      // распознаватель пишет то, что записал. Зато он обязан не считать
      // ошибкой промах самого распознавателя.
      expect(prompt(), contains('TYPED BY A MACHINE, NOT BY HIM'));
      expect(prompt(), contains('recogniser mishearing him'));
    });

    test('запятые и заглавные буквы не ошибка', () {
      // Их в речи нет: их дописывает сама модель, когда пишет "heard".
      expect(prompt(), contains('so they are never'));
    });

    test('смысл проверяется по частям, а не на слух «звучит складно»', () {
      // Смысл — первый из трёх видов ошибки, и перечислено, по чему он
      // расходится: действие, место, направление, время, лицо.
      // Смысл сверяется с ОБРАЗЦОМ, а не с ощущением «звучит складно»:
      // образец решает, ЧТО должно быть сказано, и не решает, какими словами.
      expect(prompt(), contains('Use it for MEANING ONLY'));
      expect(prompt(), contains('which day, which time, which action, who does it'));
    });

    test('перевод всегда, объяснение — только за грамматику', () {
      // Что значат слова — игрок не знает, и это перевод. Почему его
      // «many sleep» стало «sleeps a lot» — он тоже не знает, и одной фразы
      // про правило тут мало не бывает. А на «сказал другими словами»
      // объяснять нечего: правки там нет.
      final s = prompt();
      expect(s, contains('THIS IS A TRANSLATION with a brief explanation'));
      expect(s, contains('an explanation is required'));
      expect(s, contains('ONLY the translation'));
      // Порядок задан: сначала перевод, потом объяснение. Иначе плашка
      // читается как урок грамматики, а перевода в ней будто и нет.
      expect(s, contains('The translation comes first, the explanation after it'));
      // И придирка объяснением не прикрывается: «я бы сказал иначе» — не
      // грамматическая ошибка.
      expect(s, contains('Wording you would have preferred is NOT a grammatical error'));
    });
  });

  test('список категорий ошибок только растёт', () {
    // Миграция уже падала на живой базе: из CHECK выпало значение
    // 'missing' (миграция 0038), а строки с ним у игрока лежали.
    final checks = <String, Set<String>>{};
    for (final path in Directory('supabase/migrations').listSync().whereType<File>()) {
      final text = path.readAsStringSync();
      for (final m in RegExp(r'check \(category in \(([^)]*)\)\)', dotAll: true).allMatches(text)) {
        checks[path.path] =
            RegExp(r"'([a-z_]+)'").allMatches(m.group(1)!).map((v) => v.group(1)!).toSet();
      }
    }
    final ordered = checks.keys.toList()..sort();
    final everAllowed = <String>{};
    for (final path in ordered) {
      expect(checks[path], containsAll(everAllowed),
          reason: 'из CHECK нельзя выбрасывать значения: строки с ними уже в базе ($path)');
      everAllowed.addAll(checks[path]!);
    }
  });

  group('судья правит перевод, а не стиль', () {
    // СПИСКА ОШИБОК НА ЭТОЙ ВЕТКЕ НЕТ: плашка — это сам красный текст в
    // ленте, а нажатие показывает перевод. Значит и придраться судье негде,
    // кроме «правильного перевода», — правило про него единственное, что от
    // этого защищает, и проверять надо именно его.
    test('свои слова игрока остаются в переводе нетронутыми', () {
      final s = prompt();
      expect(s, contains('HIS OWN WORDS everywhere he was right'));
      // Перечислено, что именно верно, даже если сказано не так, как сказал
      // бы судья. Перечислять запрещённые ПАРЫ нельзя: названная пара
      // становится модели доступной.
      expect(s, contains('a synonym, another order, another structure'));
      expect(s, contains('must leave every one of them untouched'));
    });

    test('чужие слова ставятся только по трём причинам', () {
      // Те же три вида ошибки, что были списком: смысл, грамматика, слово.
      expect(prompt(), contains('Put other words ONLY where what he said states something the'));
      expect(prompt(), contains('is ungrammatical, or is not a real word'));
    });

    test('объяснение не становится поводом придраться', () {
      final s = prompt();
      // Объяснение положено ровно там, где была грамматическая правка, —
      // и ни строчкой шире. Иначе модель начнёт находить грамматику там,
      // где у игрока просто другие слова: это ровно та придирка, из-за
      // которой списка ошибок здесь больше нет.
      expect(s, contains('Wording you would have preferred is NOT a grammatical error'));
      expect(s, contains('does not carry a visible'));
      // Язык плашки по-прежнему назван дважды — и требованием, и
      // самоназванием: «explain in Russian» однажды прочли как пожелание.
      expect(s, contains(r'in ${v.native} (${v.nativeSelf}) and no other language'));
    });

    test('несказанное режется лентой, а не моделью', () {
      // Подряд идущее несказанное — ОДИН кусок любой длины: «so it is» это
      // одна плашка, а не три.
      expect(prompt(), contains('did not say is ONE entry, however long'));
      // Границы всё равно проводит дифф, а перечисление модели только
      // привязывает к ним переводы — не совпавшее остаётся без перевода.
      final s = judge();
      expect(s, contains('export function attachMeanings'));
      expect(s, contains('Показать перевод НЕ ОТ ТОГО'));
    });
  });
  group('разбирать нечего — балла нет вовсе', () {
    test('соло не получает балл ни за молчание модели, ни за невнятную речь', () {
      // Раньше это были нейтральные семь и ноль. Оба числа закрывали
      // раунд оценкой за то, чего никто не слышал.
      expect(worker(),
          contains('recording.training_round_id && !verdict.degraded && !verdict.silent'));
    });

    test('экран просит ответить ещё раз и возвращает микрофон', () {
      final s = screen();
      expect(s, contains("const _judgeSilentNote = 'Модель не ответила. Попробуй ещё раз или зайди позже.';"));
      expect(s, contains('const _speechUnclearNote ='));
      // Пустой final_score читается как «оцени заново».
      expect(s, contains('if (score == null) {'));
      expect(s, contains('_stage = _Stage.awaitingAnswer;'));
      expect(s, contains("_ when clientFailure != null => ('МОДЕЛЬ НЕ ОТВЕТИЛА', AppColors.danger)"));
      expect(s, contains("TranscriptStatus.empty => ('РЕЧИ НЕ РАЗОБРАТЬ', AppColors.danger)"));
      // Нейтрального балла в соло не осталось ни в одном исходе.
      expect(s.contains('_neutralScore'), isFalse);
    });

    test('причина называется своя, а не общая', () {
      // «Модель не ответила» на невнятной записи было бы неправдой: она
      // ответила, просто разбирать оказалось нечего.
      final s = screen();
      expect(s, contains('static String _reasonFor(RecordingOutcome outcome)'));
      expect(s, contains('return _speechUnclearNote;'));
      // Чужой язык — своя причина: «модель не ответила» было бы неправдой
      // и здесь тоже.
      expect(s, contains('return _wrongLanguageNote;'));
    });

    test('в бою балл остаётся нейтральным — иначе раунд не сдвинется', () {
      // Там раунд ждёт оценки обоих, и соперник ждал бы нашего сбоя.
      final s = worker();
      expect(s, contains('score = NEUTRAL_SCORE;'));
      expect(s, contains('.from("round_scores").upsert('));
      // И игрок видит, почему разбора нет, а не голый балл.
      expect(read('lib/features/battle/battle_screen.dart'),
          contains('Модель не ответила — балл нейтральный, не в минус тебе'));
    });
  });

  test('повторная запись не перезаписывает прежний файл', () {
    // Игрок отвечал заново после «речи не разобрать», запись шла по тому
    // же пути, Storage считал это обновлением — а политика на бакете
    // разрешала только вставку. Игрок получал 403 и больше ничего
    // записать не мог.
    expect(read('lib/data/voice_submission.dart'), contains('int take = 1,'));
    expect(screen(), contains('take: ++_takeNumber,'));
    // И сама политика: upsert: true стоит во всех загрузках, и без
    // разрешения на обновление этот флаг молча работает лишь на новых
    // объектах.
    expect(read('supabase/migrations/0045_storage_overwrite.sql'),
        contains('on storage.objects for update'));
  });

  group('«речи не слышу» — ответ модели, а не наш сбой', () {
    test('отделено от «модель не ответила»', () {
      final s = judge();
      // Аудио до модели доехало: мы сами его отправили и знаем размер.
      // Значит это не наш сбой, а ответ — разбирать было нечего.
      expect(s, contains('silent?: boolean;'));
      expect(read('supabase/functions/_shared/textJudge.ts'), contains('silent: true,'));
      expect(s.contains('return fail("модель не слышит речи'), isFalse);
    });

    test('воркер помечает запись пустой, а ноль остаётся только бою', () {
      // В соло раунд не закрывается вовсе, но бой без оценки обоих не
      // сдвинется — там ноль и есть честный итог за нерасслышанное.
      final s = worker();
      expect(s, contains('} else if (verdict.silent) {'));
      expect(s, contains('score = SILENT_SCORE;'));
      expect(s, contains('transcriptStatus = "empty";'));
      expect(s, contains('transcript_status: transcriptStatus,'));
      expect(read('supabase/functions/_shared/cefr.ts'), contains('export const SILENT_SCORE = 0;'));
    });

    test('ноль разрешён схемой', () {
      final sql = read('supabase/migrations/0044_zero_score.sql');
      expect(sql, contains('check (final_score between 0 and 10)'));
      expect(sql, contains('check (score between 0 and 10)'));
    });

    test('формула балла ниже единицы не опускается', () {
      // Ноль означает «разбирать нечего». Если модель речь разобрала,
      // игрок что-то сказал, и минимум для него — единица.
      expect(judge(), contains('return Math.max(1, Math.min(10, score));'));
    });

    test('карточка балла показывается только с настоящим баллом', () {
      // Приписок «балл нейтральный, не в минус тебе» больше нет: раунд, в
      // котором разбирать было нечего, до карточки не доходит.
      final s = screen();
      expect(s.contains('балл нейтральный, не в минус тебе'), isFalse);
      expect(s.contains('оценивать было нечего'), isFalse);
    });
  });
}
