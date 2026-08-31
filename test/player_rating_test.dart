import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/leagues.dart';
import 'package:language_battle/data/player_rating.dart';

/// Главный риск перехода с эло на Glicko-2 — перепутать два числа: сам
/// рейтинг и консервативную оценку, по которой считается лига. Разница
/// между ними у новичка 700 очков, то есть две лиги, поэтому проверяем
/// каждое место, где они могли бы разъехаться.
void main() {
  test('новичок — 1500 ± 350 и первая лига', () {
    const r = PlayerRating.newcomer;
    expect(r.display, 1500);
    expect(r.deviation, 350);
    expect(r.leagueRating, 800);
    expect(r.league.cefr, 'A1');
    expect(r.levelIndex, 0);
    expect(r.isProvisional, isTrue);
  });

  test('лига считается по league_rating, а не по рейтингу', () {
    // Сырой рейтинг 2500 — это C2, но система в нём не уверена, и в зачёт
    // идёт 1800. Если тут окажется C2, значит где-то читается не та колонка.
    final r = PlayerRating.fromRow(const {
      'rating': 2500.0,
      'rating_deviation': 350.0,
      'league_rating': 1800,
    });
    expect(r.display, 2500);
    expect(r.league.cefr, 'B2');
    expect(r.levelIndex, 3);
  });

  test('нет строки или нет колонок — считаем новичком', () {
    expect(PlayerRating.fromRow(null).display, 1500);
    expect(PlayerRating.fromRow(const {}).leagueRating, 800);
  });

  test('без league_rating в выборке он пересчитывается, а не подменяется рейтингом', () {
    final r = PlayerRating.fromRow(const {
      'rating': 1900.0,
      'rating_deviation': 120.0,
    });
    expect(r.leagueRating, 1660);
    expect(r.league.cefr, 'B1');
  });

  test('прогресс внутри лиги и остаток до следующей — по league_rating', () {
    final r = PlayerRating.fromRow(const {
      'rating': 2050.0,
      'rating_deviation': 100.0,
      'league_rating': 1850,
    });
    final band = r.league;
    expect(band.cefr, 'B2');
    expect(r.bandProgress, closeTo((1850 - band.min) / (band.max - band.min), 1e-9));
    expect(r.toNextLeague, band.max - 1850);
  });

  test('в верхней лиге идти некуда', () {
    final r = PlayerRating.fromRow(const {
      'rating': 3200.0,
      'rating_deviation': 60.0,
      'league_rating': 3080,
    });
    expect(r.league.cefr, leagueBands.last.cefr);
    expect(r.toNextLeague, isNull);
    expect(r.bandProgress, 1);
  });

  test('оценка хода рейтинга совпадает со значениями glicko2_update в SQL', () {
    // Эталон получен запросом к glicko2_update(1500, RD, 0.06, 1500, RD, 1, 0):
    // победа над равным соперником при равном RD.
    const expected = {350: 162, 250: 107, 200: 79, 150: 51, 100: 26, 50: 7, 30: 3};
    expected.forEach((rd, change) {
      final r = PlayerRating(
        rating: 1500,
        deviation: rd.toDouble(),
        leagueRating: 1500 - 2 * rd,
      );
      expect(r.estimatedSwing, change, reason: 'RD $rd');
    });
  });

  test('«предварительный» гаснет, когда система уже уверена', () {
    expect(
      const PlayerRating(rating: 1600, deviation: 60, leagueRating: 1480)
          .isProvisional,
      isFalse,
    );
  });
}
