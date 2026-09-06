import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'correction_text.dart';
import 'speak_button.dart';

/// Блок «Разбор:» — как это должно было прозвучать.
///
/// «ГОЛОСОВОГО» ЗДЕСЬ БОЛЬШЕ НЕТ. Раньше сверху стояла расшифровка
/// сказанного, и её приходилось отдельно просить у провайдера. Теперь речь
/// разбирает мультимодальная модель: она слышит запись напрямую и текстом
/// её не переводит. Просить расшифровку ради строки на экране значило бы
/// платить за второй проход по тому же аудио.
///
/// Что игрок сказал не так, видно прямо здесь: его слова вплетены в
/// правильный перевод и перечёркнуты, а несказанное выделено красным.
/// Границы провела модель — приложение только красит.
class TranscriptReview extends StatelessWidget {
  /// Разбор одной лентой, как его разметила модель. Пусто — показывать
  /// нечего.
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
  Widget build(BuildContext context) {
    if (spans.isEmpty) return const SizedBox.shrink();
    // Озвучиваем ПРАВИЛЬНЫЙ вариант, а не всю ленту: зачёркнутое — это
    // ошибка игрока, и читать её вслух как образец нельзя.
    final correct = correctFromSpans(spans);
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
            SpeakButton(text: correct, languageCode: targetLanguage),
          ],
        ),
        const SizedBox(height: 3),
        SelectableText.rich(
          TextSpan(children: reviewSpans(spans)),
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
      ],
    );
  }
}
