import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/theme.dart';
import 'package:language_battle/widgets/correction_text.dart';

/// Проверка ровно того требования, которое дважды приходилось смотреть по
/// скриншотам: неверное — красным, пропущенное — зелёным, и ни одной линии
/// сверху, снизу или поперёк.
void main() {
  TextStyle styleOf(List<TextSpan> spans, String word) =>
      spans.firstWhere((s) => s.text == word).style!;

  test('сказанное неверно — красным, без декораций', () {
    final spans = correctionSpans('my mother go to shop', 'my mother goes to shop');
    expect(styleOf(spans, 'go').color, AppColors.danger);
    expect(styleOf(spans, 'go').decoration, isNull);
  });

  test('пропущенное — зелёным, без декораций', () {
    final spans = correctionSpans('for my family', 'for our whole family');
    expect(styleOf(spans, 'our').color, AppColors.ok);
    expect(styleOf(spans, 'whole').color, AppColors.ok);
    expect(styleOf(spans, 'our').decoration, isNull);
    expect(styleOf(spans, 'whole').decoration, isNull);
  });

  test('верное — обычным цветом', () {
    final spans = correctionSpans('my mother go', 'my mother goes');
    expect(styleOf(spans, 'my').color, AppColors.cream);
    expect(styleOf(spans, 'mother').color, AppColors.cream);
  });

  test('ни один фрагмент не подчёркнут и не зачёркнут', () {
    final spans = correctionSpans(
      'My mother. Every morning. Cook cooking. Breakfast. For. My family.',
      'My mother cooks a delicious breakfast for our whole family every morning.',
    );
    for (final span in spans) {
      expect(span.style?.decoration ?? TextDecoration.none, TextDecoration.none,
          reason: 'фрагмент «${span.text}» оформлен линией');
    }
  });

  test('самоисправление не красится в ошибку', () {
    // Судья присылает cleaned без брошенного варианта — сравниваем с ним.
    final spans = correctionSpans('Go to the shop', 'Go to the shop');
    expect(spans.every((s) => s.text == ' ' || s.style!.color == AppColors.cream), isTrue);
  });
}
