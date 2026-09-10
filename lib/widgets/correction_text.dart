import 'package:flutter/gestures.dart';
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

  /// Перевод куска на родной язык. Только у `miss`, и не всегда.
  ///
  /// КРАСНЫЙ ТЕКСТ И ЕСТЬ ПЛАШКА. Раньше под разбором стоял отдельный ряд
  /// плашек с объяснениями «почему так неверно». Игроку нужно другое: что
  /// ЗНАЧАТ слова, которых он не сказал, — почему неверно он и так видит,
  /// его зачёркнутое слово стоит рядом с верным.
  ///
  /// Пусто — нажимать не на что. Показать перевод не от того куска хуже,
  /// чем не показать никакого.
  final String means;

  const ReviewSpan({required this.kind, required this.text, this.means = ''});

  bool get hasMeaning => kind == 'miss' && means.isNotEmpty;

  static List<ReviewSpan> fromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <ReviewSpan>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final kind = (item['k'] as String?) ?? '';
      final text = (item['t'] as String?) ?? '';
      if (text.isEmpty) continue;
      if (kind != 'ok' && kind != 'bad' && kind != 'miss') continue;
      out.add(ReviewSpan(
        kind: kind,
        text: text,
        means: ((item['m'] as String?) ?? '').trim(),
      ));
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
List<TextSpan> reviewSpans(
  List<ReviewSpan> spans, {
  /// Чем нажимать на красный кусок. null — разбор только для чтения.
  GestureRecognizer? Function(ReviewSpan span)? recognizerFor,
}) {
  final out = <TextSpan>[];
  for (final span in spans) {
    if (span.kind != 'bad') {
      final missed = span.kind == 'miss';
      // Подчёркивание только там, где есть что показать: красный текст без
      // перевода нажимать не на что, и обещать нажатие нельзя.
      final tappable = missed && span.hasMeaning;
      out.add(TextSpan(
        text: span.text,
        recognizer: tappable ? recognizerFor?.call(span) : null,
        style: missed
            ? TextStyle(
                color: AppColors.danger,
                fontWeight: FontWeight.w700,
                decoration: tappable ? TextDecoration.underline : null,
                decorationColor: AppColors.danger.withValues(alpha: 0.45),
              )
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
