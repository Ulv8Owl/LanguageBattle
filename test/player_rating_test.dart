import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/leagues.dart';
import 'package:language_battle/data/player_rating.dart';

/// На Эло рейтинг игрока, его лига и сложность выдаваемых фраз — ОДНО
/// число, и главная проверка здесь именно эта: нигде не должно остаться
/// пересчёта «рейтинг минус два отклонения», которым жил Glicko-2 и из-за
/// которого показанное число и лига расходились на две лиги.
///
/// Значения K продублированы из public.elo_k (миграция 0026): SQL из теста
/// не вызвать, поэтому лестница проверяется на копии, а сама копия
/// подписана в player_rating.dart как копия.
void main() {
  test('новичок — 600 (середина Олова, A1) и не откалиброван', () {
    const r = PlayerRating.newcomer;
    expect(r.display, 600);
    expect(r.leagueRating, 600);
    expect(r.matchesPlayed, 0);
    expect(r.league.cefr, 'A1');
    expect(r.levelIndex, 0);
    expect(r.isProvisional, isTrue);
  });

  test('лига считается по тому же числу, что показано игроку', () {
    final r = PlayerRating.fromRow(const {
      'rating': 1850.0,
      'league_rating': 1850,
      'matches_played': 30,
    });
    expect(r.display, 1850);
    expect(r.league.cefr, 'B2');
    expect(r.levelIndex, 3);
    expect(r.isProvisional, isFalse);
  });

  test('нет строки или нет колонок — считаем новичком', () {
    expect(PlayerRating.fromRow(null).display, 600);
    expect(PlayerRating.fromRow(const {}).leagueRating, 600);
  });

  test('без league_rating в выборке берётся округлённый рейтинг', () {
    // На Glicko-2 здесь пришлось бы вычитать два отклонения; на Эло
    // подставить сам рейтинг — правильно, а не «поднять игрока на лигу».
    final r = PlayerRating.fromRow(const {'rating': 1900.4});
    expect(r.leagueRating, 1900);
    expect(r.league.cefr, 'B2');
  });

  test('прогресс внутри лиги и остаток до следующей', () {
    final r = PlayerRating.fromRow(const {
      'rating': 1850.0,
      'league_rating': 1850,
      'matches_played': 12,
    });
    final band = r.league;
    expect(band.cefr, 'B2');
    expect(r.bandProgress, closeTo((1850 - band.min) / (band.max - band.min), 1e-9));
    expect(r.toNextLeague, band.max - 1850);
  });

  test('в верхней лиге идти некуда', () {
    final r = PlayerRating.fromRow(const {
      'rating': 3200.0,
      'league_rating': 3200,
      'matches_played': 90,
    });
    expect(r.league.cefr, leagueBands.last.cefr);
    expect(r.toNextLeague, isNull);
    expect(r.bandProgress, 1);
  });

  test('лестница K повторяет public.elo_k', () {
    // Калибровка: первые 10 матчей вдвое дороже обычных.
    expect(const PlayerRating(rating: 1500, leagueRating: 1500, matchesPlayed: 0).kFactor, 40);
    expect(const PlayerRating(rating: 1500, leagueRating: 1500, matchesPlayed: 9).kFactor, 40);
    // Ровно на границе калибровка уже закончилась.
    expect(const PlayerRating(rating: 1500, leagueRating: 1500, matchesPlayed: 10).kFactor, 20);
    // В Алмазе (2400+) рейтинг должен быть устойчивым.
    expect(const PlayerRating(rating: 2400, leagueRating: 2400, matchesPlayed: 50).kFactor, 10);
    // Но не у того, кто ещё калибруется: калибровка важнее потолка.
    expect(const PlayerRating(rating: 2400, leagueRating: 2400, matchesPlayed: 3).kFactor, 40);
  });

  test('«±N» в карточке режима — половина K', () {
    // Против равного соперника E = 0.5, значит изменение = K * (1 - 0.5).
    expect(const PlayerRating(rating: 1500, leagueRating: 1500, matchesPlayed: 0).estimatedSwing, 20);
    expect(const PlayerRating(rating: 1500, leagueRating: 1500, matchesPlayed: 25).estimatedSwing, 10);
    expect(const PlayerRating(rating: 2500, leagueRating: 2500, matchesPlayed: 25).estimatedSwing, 5);
  });

  test('«предварительный» гаснет после калибровочных матчей', () {
    expect(
      const PlayerRating(rating: 1600, leagueRating: 1600, matchesPlayed: 10)
          .isProvisional,
      isFalse,
    );
  });
}
