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
      expect(judge(), contains('SELF-CORRECTION IS NOT AN ERROR'));
    });

    test('запятые и заглавные буквы не ошибка', () {
      // Их в речи нет: их дописывает сама модель, когда пишет "heard".
      expect(judge(), contains('NEVER mark punctuation, capitalisation or sentence boundaries'));
    });

    test('смысл проверяется по частям, а не на слух «звучит складно»', () {
      expect(judge(), contains('CHECK THE MEANING PART BY PART'));
    });

    test('объяснение — про эту фразу, а не выдуманное правило', () {
      expect(judge(), contains('EXPLAIN THIS SENTENCE, NOT THE LANGUAGE'));
      expect(judge(), contains('Do not state a general rule'));
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
}
