import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'correction_text.dart';
import 'speak_button.dart';

/// Два блока разбора: что услышало распознавание и как это должно звучать.
///
/// Общий для всех трёх режимов. Раньше эта разметка жила внутри экрана
/// Одиночной Игры, и в бою её просто не было: там ИИ выдавал текстовые
/// пояснения к паре ошибок, а увидеть свою фразу целиком с правкой было
/// негде.
class TranscriptReview extends StatelessWidget {
  /// Что услышало распознавание — дословно, без правок.
  final String transcript;

  /// С чем сравнивается [corrected]: очищенный от самоисправлений текст,
  /// если судья его прислал, иначе — тот же [transcript].
  final String spoken;

  /// Тот же ответ, но исправленный. Пусто — сравнивать не с чем.
  final String corrected;

  /// Изучаемый язык — на нём и только на нём озвучивается исправленная
  /// фраза. Пусто — значка динамика не будет: подставить язык «по
  /// умолчанию» здесь нельзя, иначе английскую фразу однажды прочитают
  /// по-русски и подадут это как образец произношения.
  final String targetLanguage;

  const TranscriptReview({
    super.key,
    required this.transcript,
    required this.spoken,
    required this.corrected,
    this.targetLanguage = '',
  });

  @override
  Widget build(BuildContext context) {
    if (transcript.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _label('Голосовое:'),
        const SizedBox(height: 3),
        SelectableText(
          transcript,
          style: const TextStyle(color: AppColors.cream, fontSize: 13, height: 1.4),
        ),
        if (corrected.isNotEmpty) ...[
          const SizedBox(height: 10),
          // Значок стоит у заголовка, а не в конце текста: фраза бывает в
          // несколько строк, и кнопка, уехавшая под неё, читается как
          // отдельный элемент, а не как «послушать вот это».
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              _label('Разбор:'),
              SpeakButton(text: corrected, languageCode: targetLanguage),
            ],
          ),
          const SizedBox(height: 3),
          SelectableText.rich(
            TextSpan(children: correctionSpans(spoken, corrected)),
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
        ],
      ],
    );
  }

  Widget _label(String text) => Text(
        text,
        style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.muted),
      );
}
