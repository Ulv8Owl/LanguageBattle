import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'correction_text.dart';
import 'speak_button.dart';

/// Блок «Разбор:» — как это должно было прозвучать.
///
/// КРАСНЫЙ ТЕКСТ И ЕСТЬ ПЛАШКА. Раньше под лентой стоял отдельный ряд
/// плашек с объяснениями «почему так неверно», а над ними серая подсказка.
/// Плашки дублировали то, что и так видно в ленте, а объяснение отвечало на
/// вопрос, которого игрок не задавал: почему неверно, он видит сам — его
/// зачёркнутое слово стоит вплотную к верному. Не знает он другого — ЧТО
/// ЗНАЧАТ слова, которых он не сказал.
///
/// Поэтому нажимается сам красный кусок, а снизу выезжает его перевод.
/// Границы кусков — те же, что в ленте: подряд идущее несказанное это один
/// кусок, какой бы длины он ни был, и режется он только там, где между
/// словами вклинилось сказанное — верное или зачёркнутое.
///
/// ТЕКСТ ЗДЕСЬ НЕ ВЫДЕЛЯЕТСЯ, и это плата за нажатие: SelectableText отдаёт
/// касание выделению, и до обработчика оно не доходит. Выделять разбор
/// незачем, а нажимать на него — вся суть.
class TranscriptReview extends StatefulWidget {
  /// Разбор одной лентой. Пусто — показывать нечего.
  final List<ReviewSpan> spans;

  /// Изучаемый язык — на нём и только на нём озвучивается фраза. Пусто —
  /// значка динамика не будет: подставить язык «по умолчанию» здесь
  /// нельзя, иначе английскую фразу однажды прочитают по-русски и подадут
  /// это как образец произношения.
  final String targetLanguage;

  const TranscriptReview({
    super.key,
    required this.spans,
    this.targetLanguage = '',
  });

  @override
  State<TranscriptReview> createState() => _TranscriptReviewState();
}

class _TranscriptReviewState extends State<TranscriptReview> {
  /// Распознаватели касаний живут ровно столько же, сколько виджет.
  ///
  /// Их обязательно освобождать: TapGestureRecognizer держит подписку на
  /// события указателя, и созданный в build() на каждой перерисовке он
  /// молча накапливается.
  final List<TapGestureRecognizer> _taps = [];

  @override
  void dispose() {
    for (final tap in _taps) {
      tap.dispose();
    }
    super.dispose();
  }

  void _clearTaps() {
    for (final tap in _taps) {
      tap.dispose();
    }
    _taps.clear();
  }

  /// Перевод куска — снизу, как раньше показывалось объяснение ошибки.
  void _showMeaning(ReviewSpan span) {
    final words = span.text.trim();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.navy2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.lineStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      words,
                      style: AppFonts.ui(
                          fontSize: 17, weight: FontWeight.w800, color: AppColors.danger),
                    ),
                  ),
                  // Послушать можно именно этот кусок: он на изучаемом
                  // языке, и произнести его игроку как раз и не удалось.
                  SpeakButton(text: words, languageCode: widget.targetLanguage),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                span.means,
                style: const TextStyle(color: AppColors.cream, fontSize: 15, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.spans.isEmpty) return const SizedBox.shrink();
    // Озвучиваем ПРАВИЛЬНЫЙ вариант, а не всю ленту: зачёркнутое — это
    // ошибка игрока, и читать её вслух как образец нельзя.
    final correct = correctFromSpans(widget.spans);

    _clearTaps();
    final rich = reviewSpans(
      widget.spans,
      recognizerFor: (span) {
        final tap = TapGestureRecognizer()..onTap = () => _showMeaning(span);
        _taps.add(tap);
        return tap;
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Значок стоит у заголовка, а не в конце текста: фраза бывает в
        // несколько строк, и кнопка, уехавшая под неё, читается как
        // отдельный элемент, а не как «послушать вот это».
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Разбор:',
              style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.muted),
            ),
            SpeakButton(text: correct, languageCode: widget.targetLanguage),
          ],
        ),
        const SizedBox(height: 3),
        Text.rich(
          TextSpan(children: rich),
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
      ],
    );
  }
}
