import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Высота свёрнутой шторки — столько же места раздел оставляет ей сверху.
///
/// Число живёт здесь, а не у раздела: разойдутся — свёрнутая шторка либо
/// налезет на вкладки, либо повиснет над ними с дырой.
const double chatDrawerCollapsedHeight = 40;

/// Толщина рамки. Она СЪЕДАЕТ высоту у содержимого — на неё же полоску и
/// укорачиваем, иначе свёрнутая шторка не сходится сама с собой на два
/// пикселя и Flutter ругается переполнением.
const double _borderWidth = 1;

/// Выдвижная шторка чата — ОДИН предмет: окно и полоска под ним.
///
/// ПОЧЕМУ ЭТО ВАЖНО. Раньше полоска была отдельной плашкой со своей рамкой
/// и тянула за собой вторую плашку — окно чата. На экране это читалось как
/// два предмета, один из которых непонятно почему приклеен к другому.
/// Здесь рамка и фон ровно одни, а полоска нарисована внутри, у нижнего
/// края: свёрнутая шторка и есть эта полоска, раскрытая — то же окно,
/// просто выросшее вверх... точнее вниз, а полоска уехала вместе с его
/// нижним краем.
///
/// ШТОРКА НАКРЫВАЕТ, А НЕ РАЗДВИГАЕТ. Раздел под ней остаётся на месте:
/// вкладки не уезжают вниз, список не прыгает. Поэтому её кладут в Stack
/// поверх содержимого, а не в Column вместе с ним.
class ChatDrawer extends StatelessWidget {
  /// Насколько раскрыта: 0 — видна одна полоска, 1 — во всю доступную высоту.
  final double openness;

  /// Во сколько шторка вырастает при полном раскрытии, без полоски.
  final double maxBodyHeight;

  /// Само окно чата. Всегда в дереве, даже у свёрнутой шторки: переписка
  /// должна быть загружена к моменту, когда её открыли.
  final Widget child;

  /// Одиночное нажатие по полоске: раскрыть или свернуть.
  final VoidCallback onTap;

  /// Палец ведёт полоску: dy в пикселях с прошлого события.
  final ValueChanged<double> onDrag;

  /// Палец отпущен: скорость по вертикали, пикселей в секунду.
  final ValueChanged<double> onSettle;

  const ChatDrawer({
    super.key,
    required this.openness,
    required this.maxBodyHeight,
    required this.child,
    required this.onTap,
    required this.onDrag,
    required this.onSettle,
  });

  @override
  Widget build(BuildContext context) {
    final body = maxBodyHeight * openness.clamp(0.0, 1.0);
    return SizedBox(
      // ШИРИНА — ВО ВСЮ ПОЛОСУ РАЗДЕЛА, как у плашек под шторкой: она их
      // продолжение, а не всплывающее окно поверх. Сказано явно, а не
      // оставлено на волю содержимого: иначе свёрнутая шторка съезжала бы
      // по ширине к своей полоске.
      width: double.infinity,
      height: chatDrawerCollapsedHeight + body,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.navy2,
          border: Border.all(color: AppColors.line, width: _borderWidth),
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // Окно живёт в ПОЛНУЮ высоту и просто обрезается: иначе список
            // сообщений пересобирался бы на каждом кадре перетаскивания, и
            // палец тащил бы не шторку, а перекладку всего чата.
            Expanded(
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: maxBodyHeight,
                  maxHeight: maxBodyHeight,
                  child: child,
                ),
              ),
            ),
            _handle(),
          ],
        ),
      ),
    );
  }

  /// Полоска у нижнего края. Работает И перетаскиванием, И нажатием: тянуть
  /// догадается не каждый, а возможность, о которой не догадались, — это
  /// возможность, которой нет.
  Widget _handle() {
    return GestureDetector(
      onTap: onTap,
      onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
      onVerticalDragEnd: (details) => onSettle(details.primaryVelocity ?? 0),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: chatDrawerCollapsedHeight - 2 * _borderWidth,
        child: Center(
          child: Container(
            width: 118,
            height: 6,
            decoration: BoxDecoration(
              color: AppColors.gold,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }
}
