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

  String judge() => read('supabase/functions/_shared/omniJudge.ts');
  String prompt() => read('supabase/functions/_shared/prompts/judge.ts');
  String worker() => read('supabase/functions/evaluate-recording/index.ts');
  String screen() => read('lib/features/training/training_screen.dart');
  String review() => read('lib/widgets/round_review.dart');
  String migration() => read('supabase/migrations/0043_one_part_round.sql');

  group('произношения в проекте не осталось', () {
    test('ни в промптах, ни в воркере, ни на экране', () {
      for (final source in {
        'omniJudge.ts': judge(),
        'evaluate-recording': worker(),
        'training_screen.dart': screen(),
        'voice_submission.dart': read('lib/data/voice_submission.dart'),
      }.entries) {
        expect(source.value.toLowerCase().contains('pronunc'), isFalse,
            reason: source.key);
        // Единственное уцелевшее упоминание — объяснение, ЗАЧЕМ модель
        // слушает звук вместо расшифровки. Это про разбор перевода.
        final mentions = 'произношени'.allMatches(source.value).length;
        expect(mentions, lessThanOrEqualTo(source.key == 'omniJudge.ts' ? 1 : 0),
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
      expect(s, contains('_mistakes.isEmpty && !_missedSomething'));
      expect(s, contains("(attempt?.reviewSpans ?? const []).any((s) => s.kind == 'miss')"));
    });

    test('подпись под лентой тоже', () {
      final s = review();
      expect(s, contains("bool get _missedSomething => spans.any((s) => s.kind == 'miss');"));
      expect(s, contains('фраза сказана не целиком'));
    });
  });

  group('промпт разбора', () {
    test('самоисправление не считается ошибкой', () {
      expect(prompt(), contains('SELF-CORRECTION IS NOT AN ERROR'));
    });

    test('запятые и заглавные буквы не ошибка', () {
      // Их в речи нет: их дописывает сама модель, когда пишет "heard".
      expect(prompt(), contains('NEVER mark punctuation, capitalisation or sentence boundaries'));
    });

    test('смысл проверяется по частям, а не на слух «звучит складно»', () {
      expect(prompt(), contains('CHECK THE MEANING PART BY PART'));
    });

    test('объяснение — про эту фразу, а не выдуманное правило', () {
      expect(prompt(), contains('EXPLAIN THIS SENTENCE, NOT THE LANGUAGE'));
      expect(prompt(), contains('Do not state a general rule'));
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

  group('модель судит перевод, а не стиль', () {
    test('правка на плашке берётся из перевода самой модели', () {
      // Настоящий случай: в ленте модель показала «My lessons are on Monday
      // and Thursday», а на плашке к той же ошибке написала «on Sunday and
      // Saturday» — предлог поправила, перепутанные дни оставила. Игрок
      // читает два разных правильных ответа подряд, и второй неверен.
      expect(prompt(), contains('EVERY "fix" MUST BE COPIED OUT OF YOUR OWN "correct"'));
      // Промпта мало: расхождение отсеивается и кодом.
      final s = judge();
      expect(s, contains('export function groundedIn(fix: string, correct: string): boolean'));
      expect(s, contains('if (!groundedIn(correction, correct)) continue;'));
    });

    test('«естественнее» — запрещённая причина', () {
      // Модель писала «"After that" is okay, but "Then" is more natural
      // here» и снимала за это балл. Она сама признаёт, что верно, — и всё
      // равно наказывает. Большинство игроков учились по учебникам и
      // грамматически правы.
      final s = prompt();
      expect(s, contains('THE WORDS "MORE NATURAL" MUST NEVER APPEAR IN YOUR ANSWER'));
      expect(s, contains('Textbook is not wrong'));
    });

    test('вид ошибки называется и проверяется кодом', () {
      // Стиля в списке видов нет намеренно: фрагмент, который не удаётся
      // отнести ни к смыслу, ни к грамматике, ни к слову, был в порядке.
      expect(prompt(), contains('NAME THE KIND OF EVERY ERROR'));
      final s = judge();
      expect(s, contains('const ERROR_KINDS = new Set(["meaning", "grammar", "word"]);'));
      expect(s, contains('if (kind.length > 0 && !ERROR_KINDS.has(kind)) continue;'));
    });

    test('в ошибку попадают только неверные слова', () {
      // «after that I do coffee» — неверно только «do coffee», а игрок
      // читал плашку так, будто «after that» тоже ошибка.
      expect(prompt(), contains('PUT ONLY THE WRONG WORDS IN "said"'));
      // Второй пример показывает это на настоящем разборе.
      expect(prompt(), contains('Second example, same task'));
    });

    test('разговорность не повод снимать балл', () {
      // «After that» вместо «Then» и «seven o'clock» вместо «seven» —
      // сказано верно, и отнимать за это балл нечестно.
      final s = prompt();
      expect(s, contains('YOU ARE NOT HERE TO POLISH HIS ENGLISH'));
      expect(s, contains('Longer is not wrong'));
      // Прежний пример В САМОМ ПРОМПТЕ учил модели ровно этой придирке:
      // показывал «After that» → «Then» как образцовую ошибку.
      expect(s.contains('"errors": [{"said": "After that", "fix": "Then"'), isFalse);
      expect(s, contains('"errors" is EMPTY here, and that is the whole point of the example'));
    });
  });

  group('разбирать нечего — балла нет вовсе', () {
    test('соло не получает балл ни за молчание модели, ни за невнятную речь', () {
      // Раньше это были нейтральные семь и ноль. Оба числа закрывали
      // раунд оценкой за то, чего никто не слышал.
      expect(worker(),
          contains('recording.training_round_id && !omni.degraded && !omni.silent'));
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
      expect(s, contains('silent: true,'));
      expect(s.contains('return fail("модель не слышит речи'), isFalse);
    });

    test('воркер помечает запись пустой, а ноль остаётся только бою', () {
      // В соло раунд не закрывается вовсе, но бой без оценки обоих не
      // сдвинется — там ноль и есть честный итог за нерасслышанное.
      final s = worker();
      expect(s, contains('if (omni.silent) {'));
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
