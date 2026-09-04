import 'package:flutter/material.dart';

import 'theme.dart';

/// Лиги: Олово → Бронза → Серебро → Золото → Платина → Алмаз.
///
/// Лига = уровень CEFR. Раньше соответствие было скрытой механикой (оно
/// ограничивает сложность фраз раунда и объяснений судьи), но игроку
/// полезнее знать, на каком уровне он занимается, чем гадать по названию
/// металла, — поэтому уровень теперь подписан прямо на кубке.
///
/// Одна таблица порогов на всё приложение: Арена рисует по ней лестницу
/// лиг, «Рейтинг» подсвечивает ей рамку аватара, банк фраз и слов берёт по
/// ней уровень сложности. Порядок и число ДОЛЖНЫ совпадать с
/// wordLevelSlugs в word_packs.dart и с league_index_for_rating в SQL.
///
/// Границы применяются к рейтингу Эло — то есть ровно к тому числу,
/// которое показано игроку (league_rating в базе, см. PlayerRating в
/// lib/data/player_rating.dart). Пороги не менялись ни при переходе на
/// Glicko-2, ни при возврате к Эло: перенос в миграции 0026 подобран так,
/// что лига ни у кого не поехала.
///
/// Эти же пороги — начальные рейтинги уровней CEFR при регистрации
/// (lib/core/cefr_levels.dart): заявивший B1 начинает ровно с 1500, то
/// есть с порога Серебра.
class League {
  final String name;
  final String shortName;

  /// Уровень CEFR этой лиги — показывается игроку.
  final String cefr;
  final int min;
  final int max;
  final Color color;

  const League({
    required this.name,
    required this.shortName,
    required this.cefr,
    required this.min,
    required this.max,
    required this.color,
  });

  /// «Олово — A1» — подпись под кубком.
  String get titleWithLevel => '$name — $cefr';

  /// Цвет текста, читаемого поверх [color]. Кубки идут от тёмно-зелёного
  /// до белого, и одним цветом надписи тут не обойтись.
  Color get onColor =>
      color.computeLuminance() > 0.45 ? const Color(0xFF10131A) : Colors.white;
}

/// Названия здесь — то, что видит игрок. В базе лига по-прежнему хранится
/// английским слагом (bronze/silver/gold/platinum/diamond/master, см.
/// league_slug_for_elo в миграции 0010), и переименование его не касается:
/// столбец служебный, логика везде считается от рейтинга. Поэтому первая
/// лига называется «Олово», а в базе у неё слаг bronze — это не рассинхрон.
const leagueBands = <League>[
  League(name: 'Олово', shortName: 'Олово', cefr: 'A1', min: 0, max: 1200, color: Color(0xFF3F7D5E)),
  League(name: 'Бронза', shortName: 'Бронза', cefr: 'A2', min: 1200, max: 1500, color: Color(0xFF9C6B3C)),
  League(name: 'Серебро', shortName: 'Серебро', cefr: 'B1', min: 1500, max: 1800, color: Color(0xFFE8E8EE)),
  League(name: 'Золото', shortName: 'Золото', cefr: 'B2', min: 1800, max: 2100, color: AppColors.gold),
  League(name: 'Платина', shortName: 'Платина', cefr: 'C1', min: 2100, max: 2400, color: Color(0xFF86D6F2)),
  League(name: 'Алмаз', shortName: 'Алмаз', cefr: 'C2', min: 2400, max: 999999, color: Color(0xFF4C82E4)),
];

/// [leagueRating] — целочисленный рейтинг игрока (колонка
/// user_languages.league_rating), он же показанный ему рейтинг Эло.
League leagueFor(int leagueRating) {
  for (final b in leagueBands) {
    if (leagueRating >= b.min && leagueRating < b.max) return b;
  }
  return leagueBands.last;
}
