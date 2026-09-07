import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'correction_text.dart';
import 'speak_button.dart';
import 'transcript_review.dart';

/// Разбор ответа — общий для всех трёх режимов.
///
/// ЗАЧЕМ ОБЩИЙ. Раньше этот разбор жил только в Одиночной Игре, а в бою
/// показывался балл и пара строк текста. Разница была не задумана — просто
/// соло делали позже и лучше. Игрок при этом учится в бою ровно так же, и
/// объяснять ему там хуже незачем.
///
/// В БОЮ ЕГО ВИДИТ ТОЛЬКО СВОЙ ХОЗЯИН. Разбор — это работа над ошибками
/// конкретного игрока: чужие ошибки сопернику ни к чему, а язык объяснений
/// у соперника вообще другой (в Дуэли родные языки противоположны).

/// Одна ошибка, названная моделью: кусок сказанного и разбор к нему.
class Mistake {
  /// Фрагмент того, что игрок СКАЗАЛ. Он же — надпись на плашке.
  final String span;

  /// Объяснение на родном языке: почему так неверно.
  final String message;

  /// Как надо было сказать этот кусок. Пусто — модель не предложила.
  final String correction;

  const Mistake({required this.span, required this.message, required this.correction});
}

/// Разбор по ОШИБКАМ, а не по элементам эталона.
///
/// ПОЧЕМУ НЕ «ФРАЗА С ПОДСВЕТКОЙ». На руках не разложенный эталон, а список
/// несвязанных фрагментов речи игрока: границы модель провела сама, по
/// смыслу, объединив в одну ошибку всё, что пошло не так по одной причине.
/// Эталона за ними нет вовсе — он в этом раунде не участвовал.
///
/// Поэтому здесь нельзя показать «всю фразу с подсветкой»: у нас на руках
/// не разложенный эталон, а список несвязанных фрагментов. Зато плашка
/// говорит ровно то, что игрок сказал, — и нажатие объясняет именно этот
/// его кусок, а не абстрактную часть правильного варианта.
class MistakeBreakdown extends StatelessWidget {
  final List<Mistake> mistakes;

  /// Изучаемый язык — для озвучки исправления.
  ///
  /// Без него «послушать, как это должно звучать» здесь пропало бы: раньше
  /// динамик стоял у исправленной фразы целиком, а у модели такой фразы
  /// нет — она правит куски. Значит и слушать надо кусок.
  final String targetLanguage;

  const MistakeBreakdown({super.key, required this.mistakes, required this.targetLanguage});

  void _show(BuildContext context, Mistake mistake) {
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
              Text(
                mistake.span,
                style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800, color: AppColors.danger),
              ),
              if (mistake.correction.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.arrow_forward, size: 14, color: AppColors.ok),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        mistake.correction,
                        style: AppFonts.ui(fontSize: 15, weight: FontWeight.w700, color: AppColors.ok),
                      ),
                    ),
                    SpeakButton(text: mistake.correction, languageCode: targetLanguage),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Text(
                mistake.message,
                style: const TextStyle(color: AppColors.cream, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 12),
              Text('разбор от ИИ', style: AppFonts.mono(fontSize: 9, color: AppColors.muted)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Нажми на кусок, чтобы понять, что с ним не так',
          style: AppFonts.ui(fontSize: 11, color: AppColors.muted),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final mistake in mistakes)
              MistakeChip(
                text: mistake.span,
                // Каждая плашка здесь — ошибка по определению: список
                // состоит только из них. Верно сказанное сюда не попадает,
                // потому что модель про него ничего и не сказала.
                missed: true,
                onTap: () => _show(context, mistake),
              ),
          ],
        ),
      ],
    );
  }
}

class MistakeChip extends StatelessWidget {
  final String text;
  final bool missed;

  /// null — по этому куску разбора нет, и нажимать не на что.
  final VoidCallback? onTap;

  const MistakeChip({
    super.key,required this.text, required this.missed, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = missed ? AppColors.danger : AppColors.lineStrong;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(8),
          color: missed ? AppColors.danger.withValues(alpha: 0.12) : Colors.transparent,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: TextStyle(
                color: missed ? AppColors.danger : AppColors.cream,
                fontSize: 12.5,
                height: 1.2,
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 5),
              Icon(Icons.help_outline, size: 12, color: AppColors.muted.withValues(alpha: 0.8)),
            ],
          ],
        ),
      ),
    );
  }
}


/// Блок разбора ответа: «Разбор:» с подсветкой и плашки ошибок.
///
/// Ровно то, что показывает Одиночная Игра, — и теперь то же самое в бою.
/// Собран отдельным виджетом, чтобы режимы не расходились: две копии одного
/// разбора неминуемо разъедутся, а игрок будет учиться по худшей.
class RoundReview extends StatelessWidget {
  /// Лента разбора: перевод с вплетёнными ошибками игрока.
  final List<ReviewSpan> spans;

  /// Ошибки с объяснениями — плашки под разбором.
  final List<Mistake> mistakes;

  /// Изучаемый язык — для озвучки правильного варианта.
  final String targetLanguage;

  /// Что написать, когда разбирать нечего: разбор не пришёл, речь не
  /// разобрана, судья не ответил. Пусто — не пишем ничего.
  final String emptyHint;

  const RoundReview({
    super.key,
    required this.spans,
    required this.mistakes,
    required this.targetLanguage,
    this.emptyHint = '',
  });

  @override
  Widget build(BuildContext context) {
    // Ленты может не быть при живом разборе — так устроена проверка
    // произношения: там оценивают звук, и текста в ответе нет вовсе.
    // Плашки при этом есть, и показать их обязательно.
    if (spans.isEmpty && mistakes.isEmpty) {
      if (emptyHint.isEmpty) return const SizedBox.shrink();
      return Text(
        emptyHint,
        style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spans.isNotEmpty) ...[
          TranscriptReview(spans: spans, targetLanguage: targetLanguage),
          const SizedBox(height: 10),
        ],
        if (mistakes.isNotEmpty)
          MistakeBreakdown(mistakes: mistakes, targetLanguage: targetLanguage)
        else
          Text(
            'Ошибок не найдено — сказано верно',
            style: AppFonts.ui(fontSize: 11, color: AppColors.muted),
          ),
      ],
    );
  }
}

/// Ошибки записи в виде, пригодном для [RoundReview].
///
/// Разбор ошибок приходит строками grammar_errors, и раскладывать их в двух
/// экранах по-разному значило бы завести две правды об одном ответе.
/// [category] — какой разбор берём: 'omni' это ошибки перевода,
/// 'pronunciation' — ошибки звука. Обе категории лежат в одной таблице, и
/// смешать их в одном блоке значило бы снять с игрока баллы дважды за одно.
List<Mistake> mistakesFrom(
  List<Map<String, dynamic>> errors, {
  String category = 'omni',
}) {
  final out = <Mistake>[];
  for (final e in errors) {
    if ((e['category'] as String?) != category) continue;
    final span = (e['span_text'] as String?)?.trim() ?? '';
    final message = (e['message'] as String?)?.trim() ?? '';
    // Плашка без фрагмента показывается не к чему, а без объяснения — это
    // пустое обещание разбора. Ни то, ни другое не показываем.
    if (span.isEmpty || message.isEmpty) continue;
    out.add(Mistake(
      span: span,
      message: message,
      correction: (e['replacement'] as String?)?.trim() ?? '',
    ));
  }
  return out;
}
