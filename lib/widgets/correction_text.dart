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

/// Разметка «Разбора:» для мультимодального пути.
///
/// ЧЕМ ОТЛИЧАЕТСЯ ОТ [correctionSpans]. Та строит правку ДИФФОМ: сравнивает
/// сказанное с правильным и сама решает, что потеряно. Здесь решать не
/// нужно — модель уже назвала куски, смысл которых игрок не передал, и
/// сказала это, СЛУШАЯ речь, а не сравнивая две строки. Диффу такое не под
/// силу: «he starts» и «he begins his work» отличаются каждым словом, но
/// потеряно там не всё.
///
/// Важнее другое: подсветка и балл обязаны опираться на один и тот же
/// список. Посчитать балл по словам модели, а покрасить по своему диффу —
/// значит показать игроку красным одно, а снять баллы за другое.
///
/// Совпадения ищутся без учёта регистра: модель цитирует свой же перевод,
/// но заглавная буква в начале предложения у неё гуляет, а терять из-за
/// этого подсветку целого куска нельзя.
List<TextSpan> missingSpans(String corrected, List<String> missing) {
  if (corrected.isEmpty) return const [];
  final marked = List<bool>.filled(corrected.length, false);
  final haystack = corrected.toLowerCase();
  for (final raw in missing) {
    final needle = raw.trim().toLowerCase();
    if (needle.isEmpty) continue;
    var from = 0;
    while (true) {
      final at = haystack.indexOf(needle, from);
      if (at < 0) break;
      for (var i = at; i < at + needle.length && i < marked.length; i++) {
        marked[i] = true;
      }
      from = at + needle.length;
    }
  }

  // Склеиваем соседние символы одного вида в один span: иначе на фразу из
  // сорока символов получится сорок TextSpan, и перенос строк начнёт
  // рваться в произвольных местах.
  final spans = <TextSpan>[];
  var start = 0;
  for (var i = 1; i <= corrected.length; i++) {
    final boundary = i == corrected.length || marked[i] != marked[start];
    if (!boundary) continue;
    spans.add(TextSpan(
      text: corrected.substring(start, i),
      style: marked[start]
          ? const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700)
          : const TextStyle(color: AppColors.cream),
    ));
    start = i;
  }
  return spans;
}
