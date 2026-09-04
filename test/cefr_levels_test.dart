import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/app_strings.dart';
import 'package:language_battle/core/cefr_levels.dart';
import 'package:language_battle/core/leagues.dart';

/// Таблица «уровень CEFR -> стартовый рейтинг» существует в двух местах:
/// в Dart (выбор уровня на экране) и в SQL (rating_for_cefr_level, который
/// этот рейтинг реально ставит). Разойдясь, они дали бы худший из возможных
/// багов: игрок выбирает «Средний», экран обещает Серебро, а рейтинг
/// приходит другой. Поэтому тест читает саму миграцию.
void main() {
  test('таблица уровней совпадает с rating_for_cefr_level в SQL', () {
    final sql = File('supabase/migrations/0028_placement_test.sql')
        .readAsStringSync();

    // Тело функции: строки вида «when 'b1' then 1500».
    final body = RegExp(
      r"create or replace function public\.rating_for_cefr_level.*?\$\$;",
      dotAll: true,
    ).firstMatch(sql);
    expect(body, isNotNull,
        reason: 'в миграции 0028 не нашлась функция rating_for_cefr_level');

    final fromSql = <String, int>{};
    for (final m in RegExp(r"when '([a-c][0-2])' then (\d+)")
        .allMatches(body!.group(0)!)) {
      fromSql[m.group(1)!] = int.parse(m.group(2)!);
    }

    final fromDart = {
      for (final level in cefrLevels) level.code: level.startingRating,
    };

    expect(fromSql, fromDart);
  });

  test('семь уровней, по одному на каждую ступень CEFR', () {
    expect(cefrLevels.map((l) => l.code).toList(),
        ['a0', 'a1', 'a2', 'b1', 'b2', 'c1', 'c2']);
  });

  test('стартовые рейтинги растут и попадают в обещанные лиги', () {
    // A0 и A1 — Олово, дальше по одной лиге на уровень. Проверяется именно
    // лига, а не число: числа могут переехать, а обещание экрана — нет.
    const expectedLeague = {
      'a0': 'A1', // Олово
      'a1': 'A1',
      'a2': 'A2', // Бронза
      'b1': 'B1', // Серебро
      'b2': 'B2', // Золото
      'c1': 'C1', // Платина
      'c2': 'C2', // Алмаз
    };
    var previous = -1;
    for (final level in cefrLevels) {
      expect(level.startingRating, greaterThan(previous),
          reason: 'рейтинги уровней должны строго расти');
      previous = level.startingRating;
      expect(leagueFor(level.startingRating).cefr, expectedLeague[level.code],
          reason: 'уровень ${level.label}');
    }
  });

  test('уровень контента не выходит за банк фраз', () {
    for (final level in cefrLevels) {
      expect(level.contentLevelIndex, inInclusiveRange(0, leagueBands.length - 1),
          reason: level.label);
    }
    // A0 и A1 делят нулевой уровень: банка «для не знающих ни слова» нет.
    expect(cefrLevelByCode('a0')!.contentLevelIndex, 0);
    expect(cefrLevelByCode('a1')!.contentLevelIndex, 0);
  });

  test('порог проверки — 60%, как обещано игроку', () {
    expect(placementPassRatio, 0.6);
    // Формулировки на обоих языках должны называть тот же процент, иначе
    // игрок увидит одно, а получит другое.
    final percent = (placementPassRatio * 100).round();
    expect(AppStrings.ru.levelCheckIntro('B1'), contains('$percent%'));
    expect(AppStrings.en.levelCheckIntro('B1'), contains('$percent%'));
  });

  test('у каждого уровня есть название на обоих языках', () {
    for (final level in cefrLevels) {
      final ru = AppStrings.ru.levelName(level.code);
      final en = AppStrings.en.levelName(level.code);
      // Заглушка (код в верхнем регистре) означает забытый уровень.
      expect(ru, isNot(level.label), reason: 'нет русского названия ${level.label}');
      expect(en, isNot(level.label), reason: 'нет английского названия ${level.label}');
      expect(ru, isNot(en), reason: 'названия ${level.label} совпали дословно');
    }
  });
}
