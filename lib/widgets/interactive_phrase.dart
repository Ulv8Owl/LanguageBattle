import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/phrase_bank.dart';

/// Задание раунда, по которому можно тыкать: каждый элемент фразы
/// переворачивается на изучаемый язык и обратно.
///
/// ЗАЧЕМ. Игрок видит фразу на родном языке и должен произнести её на
/// изучаемом. Раньше застрявшему на одном обороте оставалось только
/// промолчать и получить низкий балл, ничего при этом не поняв. Теперь
/// непонятный кусок можно подсмотреть — но не бесплатно: чем больше
/// подсказок, тем меньше награда за раунд.
///
/// ЧТО СЧИТАЕТСЯ ПОДСКАЗКОЙ. Только ПЕРВОЕ открытие элемента. Перевернув
/// его обратно, игрок уже знает перевод, и «вернуть» подсказку нельзя —
/// поэтому множество открытых не убывает, а полоска под фразой не едет
/// влево.
///
/// ГДЕ РАБОТАЕТ. Только в Одиночной Игре: там раунд про то, чтобы
/// разобраться, а не про соревнование. В бою подсказка была бы
/// преимуществом одного игрока над другим, поэтому [interactive] там
/// выключается и виджет показывает обычный текст.
class InteractivePhrase extends StatefulWidget {
  /// Элементы на языке, который ПОКАЗЫВАЕТСЯ (родном для игрока).
  final List<PhraseElement> nativeElements;

  /// Те же элементы на языке, на который надо перевести. Индекс элемента
  /// в обоих списках означает один и тот же кусок смысла — это инвариант
  /// датасета (см. PhraseEntry).
  final List<PhraseElement> targetElements;

  /// Хвост фразы после последнего элемента — точка. Не переворачивается и
  /// не нажимается.
  final String nativeTail;

  /// Можно ли подсматривать. false — просто текст (бой, уже сыгранные
  /// раунды в ленте).
  final bool interactive;

  /// Какие элементы игрок уже открывал. Живёт снаружи: открытые элементы
  /// переживают перестроение виджета и уходят в расчёт награды.
  final Set<int> revealed;

  /// Игрок открыл элемент, которого раньше не открывал.
  final ValueChanged<int>? onReveal;

  const InteractivePhrase({
    super.key,
    required this.nativeElements,
    required this.targetElements,
    required this.nativeTail,
    required this.revealed,
    this.interactive = true,
    this.onReveal,
  });

  @override
  State<InteractivePhrase> createState() => _InteractivePhraseState();
}

class _InteractivePhraseState extends State<InteractivePhrase> {
  /// Какие элементы ПОКАЗАНЫ на изучаемом языке прямо сейчас.
  ///
  /// Это НЕ то же самое, что widget.revealed: перевернув элемент обратно,
  /// игрок убирает его отсюда, но из revealed он уже не исчезнет.
  final Set<int> _flipped = {};

  /// Распознаватели тапов по элементам.
  ///
  /// TextSpan принимает GestureRecognizer, а его нужно освобождать руками.
  /// Поэтому они создаются один раз на элемент и живут вместе с этим
  /// состоянием, а не заводятся заново в каждом build(): иначе каждая
  /// перерисовка (а она случается на каждый тап) оставляла бы за собой
  /// неосвобождённый распознаватель.
  final Map<int, TapGestureRecognizer> _recognizers = {};

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  void _toggle(int index) {
    setState(() {
      if (!_flipped.remove(index)) _flipped.add(index);
    });
    if (!widget.revealed.contains(index)) widget.onReveal?.call(index);
  }

  TapGestureRecognizer _recognizerFor(int index) => _recognizers.putIfAbsent(
        index,
        () => TapGestureRecognizer()..onTap = () => _toggle(index),
      );

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(color: AppColors.cream, height: 1.5, fontSize: 15);

    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < widget.nativeElements.length; i++) ...[
            // Ведущая пунктуация и пробел — не часть элемента: точка
            // предыдущего предложения не должна мигать при тапе.
            TextSpan(text: widget.nativeElements[i].lead, style: base),
            _elementSpan(i, base),
          ],
          TextSpan(text: widget.nativeTail, style: base),
        ],
      ),
    );
  }

  TextSpan _elementSpan(int index, TextStyle base) {
    final flipped = _flipped.contains(index);
    final target = index < widget.targetElements.length
        ? widget.targetElements[index].text
        : widget.nativeElements[index].text;

    // Уже подсмотренный элемент помечен пунктиром даже когда перевёрнут
    // обратно: иначе после десятка тапов невозможно вспомнить, за что
    // списали награду, и полоска внизу выглядит взявшейся из ниоткуда.
    final seen = widget.revealed.contains(index);

    return TextSpan(
      text: flipped ? target : widget.nativeElements[index].text,
      style: base.copyWith(
        color: flipped ? AppColors.gold : AppColors.cream,
        fontWeight: flipped ? FontWeight.w700 : FontWeight.w400,
        decoration: widget.interactive && seen && !flipped
            ? TextDecoration.underline
            : TextDecoration.none,
        decorationColor: AppColors.gold.withValues(alpha: 0.45),
        decorationStyle: TextDecorationStyle.dotted,
      ),
      recognizer: widget.interactive ? _recognizerFor(index) : null,
    );
  }
}

/// Полоска подсказок под заданием: сколько элементов уже подсмотрено и во
/// что это обошлось.
///
/// Заполняется вправо и НИКОГДА не убывает — см. док-комментарий
/// [InteractivePhrase]. Процент рядом — это оставшаяся награда, а не доля
/// подсказок: игроку важно не «сколько я открыл», а «сколько мне за это
/// заплатят».
class HintMeter extends StatelessWidget {
  final int revealed;
  final int total;

  const HintMeter({super.key, required this.revealed, required this.total});

  /// Доля подсмотренного, 0..1. Она же уходит на сервер множителем награды.
  double get ratio => total == 0 ? 0 : (revealed / total).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final rewardPercent = ((1 - ratio) * 100).round();
    // Цвет ведёт от «награда цела» к «награды не осталось» — по тому же
    // смыслу, что и число рядом.
    final color = rewardPercent >= 70
        ? AppColors.ok
        : rewardPercent >= 30
            ? AppColors.gold
            : AppColors.danger;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: ratio),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                builder: (context, value, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    children: [
                      Container(height: 6, color: AppColors.navy1),
                      FractionallySizedBox(
                        widthFactor: value,
                        child: Container(height: 6, color: color),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$rewardPercent%',
              style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: color),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          revealed == 0
              ? 'Нажми на часть фразы, чтобы увидеть перевод — награда за раунд уменьшится'
              : 'Подсказок: $revealed из $total · награда $rewardPercent%',
          style: AppFonts.ui(fontSize: 10, color: AppColors.muted),
        ),
      ],
    );
  }
}
