import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/data/training_session.dart';

void main() {
  TrainingSession session(int n) =>
      TrainingSession(List.generate(n, (i) => i), random: Random(1));

  test('«знаю» закрывает слово навсегда', () {
    final s = session(3);
    final first = s.current;
    s.answer(CardOutcome.known);
    // Прогоняем всё до конца — закрытое слово не должно всплыть.
    final seen = <int>[];
    while (!s.isDone) {
      seen.add(s.current!);
      s.answer(CardOutcome.known);
    }
    expect(seen.contains(first), isFalse);
    expect(s.completed, 3);
  });

  test('«не знаю» возвращает слово скоро, а не в конец', () {
    final s = session(10);
    final word = s.current!;
    s.answer(CardOutcome.unknown);
    // Ищем, через сколько карточек оно вернётся.
    var steps = 0;
    while (s.current != word) {
      s.answer(CardOutcome.known);
      steps++;
    }
    expect(steps, lessThanOrEqualTo(3), reason: 'должно вернуться, пока свежо');
    expect(s.completed, steps, reason: 'само слово ещё не закрыто');
  });

  test('перевёрнутая карточка возвращается один раз и в конец', () {
    final s = session(4);
    final word = s.current!;
    s.answer(CardOutcome.knownAfterFlip);
    final order = <int>[];
    while (!s.isDone) {
      order.add(s.current!);
      s.answer(CardOutcome.known);
    }
    expect(order.last, word, reason: 'подсмотренное слово идёт в самый конец');
    expect(order.where((w) => w == word).length, 1, reason: 'ровно один повтор');
  });

  test('второй показ подсмотренного слова его закрывает', () {
    final s = session(1);
    s.answer(CardOutcome.knownAfterFlip);
    expect(s.isDone, isFalse);
    s.answer(CardOutcome.knownAfterFlip);
    expect(s.isDone, isTrue, reason: 'иначе слово крутилось бы вечно');
    expect(s.completed, 1);
  });

  test('счётчик считает закрытые слова, а не показы', () {
    final s = session(2);
    s.answer(CardOutcome.unknown);
    s.answer(CardOutcome.unknown);
    expect(s.completed, 0, reason: 'показов было два, закрытых слов ноль');
  });

  test('тренировка из незнакомых слов всё равно заканчивается', () {
    final s = session(5);
    var guard = 0;
    while (!s.isDone && guard < 500) {
      // Сначала не знаю, потом знаю — как и бывает на практике.
      s.answer(guard.isEven ? CardOutcome.unknown : CardOutcome.known);
      guard++;
    }
    expect(s.isDone, isTrue);
    expect(s.completed, 5);
  });
}
