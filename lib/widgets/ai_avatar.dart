import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Аватар собеседника-ИИ в ленте — хамелеон с иконки игры.
///
/// Один виджет на все режимы: и фраза раунда, и разбор приходят от одного
/// и того же собеседника, и разные картинки читались бы как разные
/// участники переписки.
class AiAvatar extends StatelessWidget {
  final double size;

  const AiAvatar({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: size,
      width: size,
      decoration: const BoxDecoration(color: AppColors.gold, shape: BoxShape.circle),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/branding/chameleon.png',
        fit: BoxFit.cover,
        // Картинка — пиксель-арт: сглаживание при уменьшении превращает её
        // в мыло, поэтому масштабируем без интерполяции.
        filterQuality: FilterQuality.none,
      ),
    );
  }
}
