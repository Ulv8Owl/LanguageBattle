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
  /// ЗНАЧАТ слова, которых он не сказал; грамматику ему поясняют там же и
  /// только тогда, когда правка её и касается.
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
  ///
  /// Кусок здесь ТОТ, ЧЕЙ ПЕРЕВОД ПОКАЗЫВАТЬ, а не тот, по которому попали
  /// пальцем: у зачёркнутого слова своего перевода нет и быть не может,
  /// показывать ему нужно перевод его исправления (см. _pairedFor).
  GestureRecognizer? Function(ReviewSpan span)? recognizerFor,
}) {
  final out = <TextSpan>[];
  for (var i = 0; i < spans.length; i++) {
    final span = spans[i];
    if (span.kind != 'bad') {
      final missed = span.kind == 'miss';
      out.add(TextSpan(
        text: span.text,
        // ПОДЧЁРКИВАНИЯ НЕТ. Красный и так виден, а линия под ним делала из
        // разбора ссылку и спорила с зачёркиванием соседнего слова.
        recognizer: missed && span.hasMeaning ? recognizerFor?.call(span) : null,
        style: missed
            ? const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700)
            : const TextStyle(color: AppColors.cream),
      ));
      continue;
    }

    // ЗАЧЁРКНУТОЕ НАЖИМАЕТСЯ ТОЖЕ. Игрок видит одно красное место — своё
    // слово и его исправление рядом — и попадает пальцем в любую половину.
    // Раньше нажималась только вторая, и выглядело это как «иногда
    // работает, иногда нет».
    final paired = _pairedFor(spans, i);

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
      out.add(TextSpan(
        text: body,
        recognizer: paired == null ? null : recognizerFor?.call(paired),
        style: _struck,
      ));
    }
    if (trailing.isNotEmpty) {
      out.add(TextSpan(text: trailing, style: const TextStyle(color: AppColors.cream)));
    }
  }
  return out;
}

/// Исправление зачёркнутого куска — то, чей перевод показать по нажатию.
///
/// СМОТРИМ ТОЛЬКО ВПЕРЁД, И ТОЛЬКО НА СОСЕДА. Замена выходит из диффа
/// одинаково: сначала слова игрока, сразу за ними недостающие верные
/// (textDiff.ts, при равенстве выбирается «сказано не так»). Заглядывать
/// назад нельзя — там стоит несказанное из ДРУГОГО места фразы, и игрок
/// получил бы перевод не от своего слова. Чужой перевод хуже, чем никакой:
/// ему поверят.
///
/// Соседа нет или он без перевода — значит игрок сказал лишнее, и
/// переводить нечего. Нажатие тогда не включается.
ReviewSpan? _pairedFor(List<ReviewSpan> spans, int i) {
  final next = i + 1 < spans.length ? spans[i + 1] : null;
  return next != null && next.hasMeaning ? next : null;
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
