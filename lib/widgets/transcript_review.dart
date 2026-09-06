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
/// Что игрок сказал не так, видно из плашек ошибок: там его собственные
/// слова, процитированные моделью, — и ровно те куски, в которых он
/// ошибся, а не вся фраза целиком.
class TranscriptReview extends StatelessWidget {
  /// Правильный перевод — его сделала модель. Пусто — показывать нечего.
  final String corrected;

  /// Изучаемый язык — на нём и только на нём озвучивается фраза. Пусто —
  /// значка динамика не будет: подставить язык «по умолчанию» здесь
  /// нельзя, иначе английскую фразу однажды прочитают по-русски и подадут
  /// это как образец произношения.
  final String targetLanguage;

  /// Куски [corrected], которых игрок не сказал, — их назвала модель.
  ///
  /// По этому же списку ей начислен балл, поэтому красим ровно его:
  /// красить одно, а снимать за другое нельзя.
  final List<String> missing;

  const TranscriptReview({
    super.key,
    required this.corrected,
    this.targetLanguage = '',
    this.missing = const [],
  });

  @override
  Widget build(BuildContext context) {
    if (corrected.isEmpty) return const SizedBox.shrink();
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
            SpeakButton(text: corrected, languageCode: targetLanguage),
          ],
        ),
        const SizedBox(height: 3),
        SelectableText.rich(
          TextSpan(children: missingSpans(corrected, missing)),
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
      ],
    );
  }
}
