import 'package:flutter/material.dart';

import '../core/text_diff.dart';
import '../core/theme.dart';

/// Разметка правки для блока «Разбор:»: тот же ответ игрока, но с
/// исправленными ошибками и добавленными пропущенными словами.
///
/// Цвета несут весь смысл, оформления больше нет никакого:
/// * красный — сказано неверно;
/// * зелёный — было пропущено и добавлено по эталону;
/// * обычный — сказано верно.
///
/// Ни подчёркиваний, ни зачёркиваний: строку читают целиком, и лишние
/// линии этому только мешают. Функция вынесена из экрана Одиночной Игры,
/// чтобы это правило можно было проверить тестом, а не глазами по скриншоту.
List<TextSpan> correctionSpans(String spoken, String corrected) {
  final parts = diffWords(spoken, corrected);
  final spans = <TextSpan>[];
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    spans.add(TextSpan(
      text: part.text,
      style: switch (part.kind) {
        DiffKind.same => const TextStyle(color: AppColors.cream),
        DiffKind.wrong => const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700),
        DiffKind.missing => const TextStyle(color: AppColors.ok, fontWeight: FontWeight.w700),
      },
    ));
    if (i != parts.length - 1) spans.add(const TextSpan(text: ' '));
  }
  return spans;
}
