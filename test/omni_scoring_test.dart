import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/theme.dart';
import 'package:language_battle/widgets/correction_text.dart';

/// Разбор приходит одной лентой: правильный перевод с вплетёнными ошибками
/// игрока. По этой же ленте считается балл — показать красным одно, а снять
/// баллы за другое стало невозможно по построению.
void main() {
  ReviewSpan ok(String t) => ReviewSpan(kind: 'ok', text: t);
  ReviewSpan bad(String t) => ReviewSpan(kind: 'bad', text: t);
  ReviewSpan miss(String t) => ReviewSpan(kind: 'miss', text: t);

  group('разметка ленты', () {
    bool isRed(TextSpan s) => s.style?.color == AppColors.danger;
    bool isStruck(TextSpan s) => s.style?.decoration == TextDecoration.lineThrough;

    test('несказанное — красным, сказанное не так — зачёркнуто', () {
      final spans = reviewSpans([
        ok('My office is near '),
        bad('I go'),
        miss('the station'),
      ]);
      expect(spans.where(isRed).map((s) => s.text).join(), 'the station');
      expect(spans.where(isStruck).map((s) => s.text).join(), 'I go');
      // Верное — обычным цветом и без зачёркивания.
      final plain = spans.firstWhere((s) => s.text == 'My office is near ');
      expect(isRed(plain), isFalse);
      expect(isStruck(plain), isFalse);
    });

    test('правильный вариант — всё, кроме слов игрока', () {
      // Его и озвучивает динамик: читать вслух ошибку как образец нельзя.
      expect(
        correctFromSpans([ok('I '), bad('go'), miss('walk'), ok(' there')]),
        'I walk there',
      );
    });

    test('чужие виды кусков отбрасываются', () {
      // Модель может прислать что угодно; красить наугад хуже, чем не
      // красить.
      final parsed = ReviewSpan.fromJson([
        {'k': 'ok', 't': 'a'},
        {'k': 'странное', 't': 'b'},
        {'k': 'miss', 't': ''},
        'мусор',
      ]);
      expect(parsed.length, 1);
      expect(parsed.single.text, 'a');
    });
  });

  group('формула балла', () {
    // Повторяет scoreFor из supabase/functions/_shared/omniJudge.ts.
    // Дублирование осознанное: тесты Deno в этом проекте не запускаются, а
    // tools/check_score_formula.ts сверяет копию с оригиналом числами.
    int score(List<ReviewSpan> review, int errors) {
      int len(String kind) => review
          .where((s) => s.kind == kind)
          .fold(0, (sum, s) => sum + s.text.trim().length);
      final total = len('ok') + len('miss');
      final share = total == 0 ? 0.0 : (len('miss') / total).clamp(0.0, 1.0);
      return (10 - (10 * share).round() - errors).clamp(1, 10);
    }

    test('сказал всё и без ошибок — десять', () {
      expect(score([ok('He starts work at six')], 0), 10);
    });

    test('не сказал 60% — минус шесть', () {
      // Ровно пример из постановки задачи.
      expect(score([ok('0123'), miss('456789')], 0), 4);
    });

    test('каждая ошибка снимает по баллу', () {
      expect(score([ok('He starts work at six')], 3), 7);
    });

    test('пропуски и ошибки складываются', () {
      expect(score([ok('01234'), miss('56789')], 2), 3);
    });

    test('ниже единицы не опускаемся', () {
      // Отрицательных баллов в игре нет: единица и есть «не получилось».
      expect(score([miss('0123456789')], 5), 1);
    });

    test('сказанное не так в знаменатель не идёт', () {
      // bad — это слова ИГРОКА, а доля считается от правильного перевода.
      // Иначе длинный неверный ответ улучшал бы балл.
      expect(score([ok('01234'), bad('очень длинная чушь'), miss('56789')], 0), 5);
    });

    test('разбора нет — отвечают только ошибки', () {
      expect(score(const [], 2), 8);
    });
  });
}
