import 'package:flutter/material.dart';

import 'theme.dart';

/// Лиги (раздел 2.6): Bronze → Silver → Gold → Platinum → Diamond → Master.
/// Одна таблица порогов на всё приложение — Арена рисует по ней лестницу
/// лиг, вкладка «Рейтинг» подсвечивает ей рамку аватара и текст рейтинга.
class League {
  final String name;
  final String shortName;
  final int min;
  final int max;
  final Color color;

  const League({
    required this.name,
    required this.shortName,
    required this.min,
    required this.max,
    required this.color,
  });
}

const leagueBands = <League>[
  League(name: 'Медная Лига', shortName: 'Медная', min: 0, max: 1200, color: Color(0xFFB5732E)),
  League(name: 'Серебряная Лига', shortName: 'Серебряная', min: 1200, max: 1500, color: AppColors.cyan),
  League(name: 'Золотая Лига', shortName: 'Золотая', min: 1500, max: 1800, color: AppColors.gold),
  League(name: 'Платиновая Лига', shortName: 'Платиновая', min: 1800, max: 2100, color: AppColors.plat),
  League(name: 'Алмазная Лига', shortName: 'Алмазная', min: 2100, max: 2400, color: AppColors.diamond),
  League(name: 'Лига Мастеров', shortName: 'Мастеров', min: 2400, max: 999999, color: AppColors.master),
];

League leagueFor(int elo) {
  for (final b in leagueBands) {
    if (elo >= b.min && elo < b.max) return b;
  }
  return leagueBands.last;
}
