import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Высота ручки вместе с отступами — раздел вычитает её из своей высоты,
/// раскладывая панель, поэтому число должно быть здесь, а не у него.
const double pullHandleHeight = 40;

/// Полоска-ручка: за неё выдвижная панель раскрывается и сворачивается.
///
/// ПОЧЕМУ ПОЛОСКА, А НЕ КНОПКА. Чат — часть раздела «Друзья», а не пятый
/// пункт внизу: там и так четыре кнопки, и пятая размыла бы то, ради чего
/// в приложение заходят. Полоска тем же жестом, что и любая шторка в
/// системе, говорит «здесь что-то выдвигается».
///
/// РАБОТАЕТ И ПЕРЕТАСКИВАНИЕМ, И НАЖАТИЕМ. Тянуть догадается не каждый, а
/// возможность, о которой не догадались, — это возможность, которой нет.
class PullHandle extends StatelessWidget {
  /// Одиночное нажатие: раскрыть или свернуть.
  final VoidCallback onTap;

  /// Палец ведёт полоску: dy в пикселях с прошлого события.
  final ValueChanged<double> onDrag;

  /// Палец отпущен: скорость по вертикали, пикселей в секунду.
  final ValueChanged<double> onSettle;

  const PullHandle({super.key, required this.onTap, required this.onDrag, required this.onSettle});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
      onVerticalDragEnd: (details) => onSettle(details.primaryVelocity ?? 0),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Container(
          height: 32,
          decoration: BoxDecoration(
            color: AppColors.navy2,
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: Container(
              width: 74,
              height: 5,
              decoration: BoxDecoration(
                color: AppColors.gold,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
