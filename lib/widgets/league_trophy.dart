import 'package:flutter/material.dart';

import '../core/leagues.dart';
import '../core/theme.dart';

/// Кубок лиги с подписанным на нём уровнем CEFR.
///
/// Уровень пишется прямо на чаше кубка, а не рядом: на лестнице из шести
/// кубков подписи сбоку сливаются в кашу, а на самом кубке каждая читается
/// вместе со своим цветом.
class LeagueTrophy extends StatelessWidget {
  final League league;
  final double size;

  /// Текущая лига игрока — светится и показана в полную силу цвета.
  /// Остальные приглушены, чтобы лестница читалась с одного взгляда.
  final bool active;

  const LeagueTrophy({
    super.key,
    required this.league,
    required this.size,
    this.active = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? league.color : league.color.withValues(alpha: 0.3);
    return SizedBox(
      height: size,
      width: size,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          if (active)
            // Мягкое свечение под кубком — иначе тёмно-зелёное олово почти
            // сливается с фоном экрана.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: size * 0.35),
                  ],
                ),
              ),
            ),
          Icon(Icons.emoji_events, size: size, color: color),
          // Чаша кубка в этой иконке занимает верхнюю часть и по ширине
          // примерно половину — надпись садится в неё.
          Positioned(
            top: size * 0.20,
            child: Text(
              league.cefr,
              style: AppFonts.ui(
                fontSize: size * 0.26,
                weight: FontWeight.w800,
                color: active ? league.onColor : league.onColor.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
