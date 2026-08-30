import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/theme.dart';
import 'package:language_battle/widgets/correction_text.dart';

/// Проверка ровно того требования, которое иначе приходится смотреть по
/// скриншотам: сказанное верно — обычным цветом, сказанное неверно —
/// обычным цветом с красной чертой поперёк, не сказанное — красным.
void main() {
  TextStyle styleOf(List<TextSpan> spans, String word) =>
      spans.firstWhere((s) => s.text == word).style!;

  test('сказанное неверно — перечёркнуто красным, но читаемо', () {
    final spans = correctionSpans('my mother go to shop', 'my mother goes to shop');
    final style = styleOf(spans, 'go');
    expect(style.color, AppColors.cream, reason: 'слово должно оставаться читаемым');
    expect(style.decoration, TextDecoration.lineThrough);
    expect(style.decorationColor, AppColors.danger);
  });

  test('не сказанное — красным и без черты', () {
    final spans = correctionSpans('for my family', 'for our whole family');
    for (final word in ['our', 'whole']) {
      final style = styleOf(spans, word);
      expect(style.color, AppColors.danger);
      expect(style.decoration ?? TextDecoration.none, TextDecoration.none);
    }
  });

  test('верное — обычным цветом и без оформления', () {
    final spans = correctionSpans('my mother go', 'my mother goes');
    for (final word in ['my', 'mother']) {
      final style = styleOf(spans, word);
      expect(style.color, AppColors.cream);
      expect(style.decoration ?? TextDecoration.none, TextDecoration.none);
    }
  });

  test('черта бывает только у сказанного неверно', () {
    final spans = correctionSpans(
      'My mother. Every morning. Cook cooking. Breakfast. For. My family.',
      'My mother cooks a delicious breakfast for our whole family every morning.',
    );
    for (final span in spans) {
      if ((span.style?.decoration ?? TextDecoration.none) == TextDecoration.lineThrough) {
        expect(span.style!.color, AppColors.cream,
            reason: 'перечёркнутое — это слова игрока, они остаются обычного цвета');
      }
    }
  });

  test('самоисправление не красится в ошибку', () {
    final spans = correctionSpans('Go to the shop', 'Go to the shop');
    expect(spans.every((s) => s.text == ' ' || s.style!.color == AppColors.cream), isTrue);
  });
}
