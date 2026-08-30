import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Аватар собеседника-ИИ в ленте — хамелеон с иконки игры.
///
/// Один виджет на все режимы: и фраза раунда, и разбор приходят от одного
/// и того же собеседника, и разные картинки читались бы как разные
/// участники переписки.
class AiAvatar extends StatelessWidget {
  final double size;

  const AiAvatar({super.key, this.size = avatarSize});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: size,
      width: size,
      decoration: const BoxDecoration(color: AppColors.gold, shape: BoxShape.circle),
      clipBehavior: Clip.antiAlias,
      // Хамелеон на исходной картинке занимает её целиком и смотрит из
      // левого верхнего угла: при обычной вписке в круг в центре оказывался
      // хвост, а морда уезжала за край. Приближаем и сдвигаем так, чтобы в
      // центре круга был глаз.
      //
      // Числа не на глаз: глаз (единственное светлое пятно на картинке)
      // лежит в точке (25, 26) изображения 77x86, то есть на 0.171 и 0.214
      // ширины круга выше и левее его центра. После увеличения в
      // [_zoom] раз это смещение растёт во столько же раз — его и
      // компенсируем сдвигом.
      child: ClipOval(
        child: Transform.translate(
          offset: Offset(0.171 * _zoom * size, 0.214 * _zoom * size),
          child: Transform.scale(
            scale: _zoom,
            child: Image.asset(
              'assets/branding/chameleon.png',
              fit: BoxFit.cover,
              // Картинка — пиксель-арт: сглаживание превращает её в мыло.
              filterQuality: FilterQuality.none,
            ),
          ),
        ),
      ),
    );
  }

  /// Во сколько раз приблизить. Меньше 1.8 не хватает запаса, чтобы сдвинуть
  /// морду в центр и при этом не открыть пустой край круга.
  static const double _zoom = 1.8;
}

/// Размер аватарки в ленте — общий для ИИ и для игроков, иначе сообщения
/// выглядят как разговор существ разного роста.
const double avatarSize = 52;

/// Единый вертикальный промежуток между соседними сообщениями ленты.
///
/// Одна константа на все виды сообщений: пока у голосовых, текстовых и
/// разборов были свои отступы, расстояния между соседними парами выходили
/// разными и лента выглядела рваной.
const double feedGap = 12;
