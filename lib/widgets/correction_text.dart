import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Один кусок разбора: текст и что с ним не так.
///
/// Границы провела МОДЕЛЬ, а не мы. Раньше приложение искало пропущенные
/// куски в правильном переводе подстрокой, и поиск промахивался на каждой
/// мелочи — неточная цитата, другой регистр, — после чего подсветка молча
/// пропадала. Теперь красить нечего решать: пришло размеченным.
class ReviewSpan {
  /// ok — сказано верно, bad — сказано не так, miss — не сказано вовсе.
  final String kind;
  final String text;

  const ReviewSpan({required this.kind, required this.text});

  static List<ReviewSpan> fromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <ReviewSpan>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final kind = (item['k'] as String?) ?? '';
      final text = (item['t'] as String?) ?? '';
      if (text.isEmpty) continue;
      if (kind != 'ok' && kind != 'bad' && kind != 'miss') continue;
      out.add(ReviewSpan(kind: kind, text: text));
    }
    return out;
  }
}

/// Правильный перевод — всё, кроме сказанного игроком неверно.
String correctFromSpans(List<ReviewSpan> spans) =>
    spans.where((s) => s.kind != 'bad').map((s) => s.text).join();

/// Разметка «Разбора:»: правильный перевод с вплетёнными ошибками игрока.
///
/// Три вида различаются так же, как различались всегда:
/// * сказано верно — обычный цвет;
/// * сказано неверно — перечёркнуто красной линией (слово видно, и видно,
///   что его надо убрать);
/// * не сказано вовсе — красным (вычёркивать нечего, это недостающее).
List<TextSpan> reviewSpans(List<ReviewSpan> spans) {
  final out = <TextSpan>[];
  for (final span in spans) {
    if (span.kind != 'bad') {
      out.add(TextSpan(
        text: span.text,
        style: span.kind == 'miss'
            ? const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700)
            : const TextStyle(color: AppColors.cream),
      ));
      continue;
    }

    // ПРОБЕЛЫ ПО КРАЯМ НЕ ЗАЧЁРКИВАЮТСЯ. Куски разбора склеиваются с
    // пробелом на стыке, и он доставался неверному слову — линия тянулась
    // из зачёркнутого слова в следующее, правильное, и выглядело это так,
    // будто убрать надо оба.
    final text = span.text;
    final body = text.trim();
    final leading = text.substring(0, text.length - text.trimLeft().length);
    final trailing = text.substring(leading.length + body.length);

    if (leading.isNotEmpty) {
      out.add(TextSpan(text: leading, style: const TextStyle(color: AppColors.cream)));
    }
    if (body.isNotEmpty) {
      out.add(TextSpan(text: body, style: _struck));
    }
    if (trailing.isNotEmpty) {
      out.add(TextSpan(text: trailing, style: const TextStyle(color: AppColors.cream)));
    }
  }
  return out;
}

/// Зачёркнутое слово игрока.
///
/// Линия ТОЛСТАЯ и того же красного, что и несказанное: на тонкой её было
/// почти не видно, и разбор читался как обычный текст с непонятными
/// красными вставками.
const TextStyle _struck = TextStyle(
  color: AppColors.cream,
  decoration: TextDecoration.lineThrough,
  decorationColor: AppColors.danger,
  decorationThickness: 3.5,
);
