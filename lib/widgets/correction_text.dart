import 'package:flutter/material.dart';

import '../core/text_diff.dart';
import '../core/theme.dart';

/// Разметка правки для блока «Разбор:»: тот же ответ игрока, но с
/// исправленными ошибками и добавленными пропущенными словами.
///
/// Три вида фрагментов различаются так:
/// * сказано верно — обычный цвет текста;
/// * сказано неверно — обычный цвет, перечёркнутый красной линией
///   (слово видно, и видно, что его надо убрать);
/// * не сказано вовсе — красным (добавлять нечего вычёркивать, это
///   недостающее).
///
/// Вынесено из экрана Одиночной Игры, чтобы правило проверялось тестом, а
/// не глазами по скриншоту, и чтобы все три режима красили одинаково.
List<TextSpan> correctionSpans(String spoken, String corrected) {
  final parts = diffWords(spoken, corrected);
  final spans = <TextSpan>[];
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    spans.add(TextSpan(
      text: part.text,
      style: switch (part.kind) {
        DiffKind.same => const TextStyle(color: AppColors.cream),
        DiffKind.wrong => const TextStyle(
            color: AppColors.cream,
            decoration: TextDecoration.lineThrough,
            decorationColor: AppColors.danger,
            decorationThickness: 2,
          ),
        DiffKind.missing => const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700),
      },
    ));
    if (i != parts.length - 1) spans.add(const TextSpan(text: ' '));
  }
  return spans;
}
