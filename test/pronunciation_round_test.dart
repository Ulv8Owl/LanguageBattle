import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Вторая попытка Одиночной Игры проверяет ПРОИЗНОШЕНИЕ, а не перевод.
///
/// ЧТО БЫЛО НЕ ТАК. Обе попытки были одной проверкой перевода. Игрок делал
/// первую, читал разбор с правильным вариантом — и повторял его во второй.
/// Балл ставился по второй, то есть по тому, что ему только что показали:
/// проверялась память на одну фразу, а не язык.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String judge() => read('supabase/functions/_shared/omniJudge.ts');
  String worker() => read('supabase/functions/evaluate-recording/index.ts');
  String screen() => read('lib/features/training/training_screen.dart');
  String migration() => read('supabase/migrations/0043_pronunciation_attempt.sql');

  group('промпт произношения', () {
    test('модель слушает звук и не пишет расшифровку', () {
      final s = judge();
      // Расшифровка — это как раз тот шаг, на котором произношение
      // теряется: распознаватель пишет слово правильно, даже когда оно
      // сказано неверно.
      expect(s, contains('Do not transcribe the recording'));
      expect(s, contains('JUDGE THE SOUND AND NOTHING ELSE'));
      // Ни "heard", ни "correct" в ответе нет — только ошибки.
      expect(s, contains('{"audible": boolean, "errors": [{"said": string, "why": string, "fix": string}]}'));
    });

    test('акцент — не ошибка', () {
      // Придуманная ошибка стоит балла и учит чинить то, что не сломано.
      expect(judge(), contains('AN ACCENT IS NOT AN ERROR'));
    });

    test('балл считает программа, а не модель', () {
      final s = judge();
      expect(s, contains('export function pronunciationScoreFor(errorCount: number): number'));
      expect(s, contains('return Math.max(1, Math.min(10, 10 - errorCount));'));
    });
  });

  group('промпт перевода', () {
    test('самоисправление не считается ошибкой', () {
      // Игрок сказал не то и поправился — это работающий навык, а не сбой.
      expect(judge(), contains('SELF-CORRECTION IS NOT AN ERROR'));
    });

    test('запятые и заглавные буквы не ошибка', () {
      // Их в речи нет: их дописывает сама модель, когда пишет "heard".
      expect(judge(), contains('NEVER mark punctuation, capitalisation or sentence boundaries'));
    });

    test('смысл проверяется по частям, а не на слух «звучит складно»', () {
      // «Мы гуляем в парке» и «мы идём в парк» — разные вещи, и вторая
      // модель принимала как верный перевод.
      expect(judge(), contains('CHECK THE MEANING PART BY PART'));
    });

    test('объяснение — про эту фразу, а не выдуманное правило', () {
      // Правило, придуманное под один пример, обычно ложно, а игрок в
      // него поверит.
      expect(judge(), contains('EXPLAIN THIS SENTENCE, NOT THE LANGUAGE'));
      expect(judge(), contains('Do not state a general rule'));
    });
  });

  group('воркер', () {
    test('роль записи берётся из своей колонки, а не из номера попытки', () {
      // Проверка уровня присылает «попытку 2» при единственной попытке в
      // раунде: вывести две роли из одного числа нельзя.
      expect(worker(), contains('if (recording.judge_mode === "pronunciation")'));
      expect(migration(), contains("check (judge_mode in ('translation', 'pronunciation'))"));
    });

    test('балл за перевод ставится по ПЕРВОЙ попытке', () {
      final s = worker();
      // Раньше здесь стояло условие attemptNumber >= 2 — то есть балл
      // ставился по фразе, только что показанной игроку в разборе.
      expect(s.contains('if (attemptNumber >= 2) {'), isFalse);
      expect(s, contains('.update({ final_score: score })'));
    });

    test('произношение пишет свой балл и не трогает ленту разбора', () {
      final s = worker();
      expect(s, contains('.update({ pronunciation_score: score })'));
      expect(s, contains('review_spans: null'));
      expect(s, contains('category: "pronunciation"'));
    });
  });

  group('экран соло', () {
    test('первая попытка называется разбором перевода', () {
      final s = screen();
      expect(s, contains("'РАЗБОР ПЕРЕВОДА'"));
      expect(s.contains('РАЗБОР ПЕРВОЙ ПОПЫТКИ'), isFalse);
      expect(s.contains('РАЗБОР ВТОРОЙ ПОПЫТКИ'), isFalse);
    });

    test('между попытками — одна строка от хамелеона', () {
      expect(screen(), contains("const _pronunciationCall = 'Теперь проверь своё произношение';"));
    });

    test('второй разбор — только плашки, без ленты', () {
      final s = screen();
      expect(s, contains("'ПРОИЗНОШЕНИЕ'"));
      // Ленты у произношения нет и быть не может: текста в ответе нет.
      expect(s, contains('spans: isPronunciation ? const [] : (attempt?.reviewSpans ?? const [])'));
      expect(s, contains("category: isPronunciation ? 'pronunciation' : 'omni'"));
    });

    test('итоги раунда — два балла', () {
      final s = screen();
      expect(s, contains("'ИТОГИ РАУНДА'"));
      expect(s, contains("Text('Перевод'"));
      expect(s, contains("Text('Произношение'"));
    });

    test('роль записи уходит на сервер явно', () {
      expect(screen(), contains("(!widget.isPlacement && attempt == 2) ? 'pronunciation' : 'translation'"));
      expect(read('lib/data/voice_submission.dart'), contains("'judge_mode': judgeMode,"));
    });
  });
}
