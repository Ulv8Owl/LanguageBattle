import '../core/leagues.dart';
import '../core/word_packs.dart';

/// Рейтинг игрока по Эло — ровно то, что лежит в user_languages.
///
/// Эло знает про игрока ОДНО число, и это же число — его лига, уровень
/// CEFR, сложность фраз и доступ к наборам слов. Так было не всегда: на
/// Glicko-2 рейтинг хранился тремя величинами, а лига считалась по
/// консервативной оценке rating - 2*RD, из-за чего показанное игроку число
/// и число, по которому ему выдавался контент, расходились на семьсот
/// очков. Объяснить это игроку было нечем — см. миграцию 0026.
///
/// [leagueRating] остаётся отдельным полем не потому, что отличается от
/// [rating], а потому, что его считает и хранит база (колонка
/// user_languages.league_rating, триггер trg_sync_rating_mirrors). Клиент
/// его только читает: так лига на экране и лига в проверках сервера не
/// могут разойтись, даже если округление где-то посчитается иначе.
class PlayerRating {
  final double rating;

  /// Целочисленный рейтинг из базы. В Эло равен округлённому [rating].
  final int leagueRating;

  /// Сколько рейтинговых матчей сыграно на этой паре. Определяет цену
  /// одного матча (K) — см. [estimatedSwing].
  final int matchesPlayed;

  const PlayerRating({
    required this.rating,
    required this.leagueRating,
    required this.matchesPlayed,
  });

  /// Пара, заведённая без выбора уровня CEFR: 600 — середина Олова, A1.
  /// То же значение, что и у public.elo_default_rating() в базе.
  static const PlayerRating newcomer =
      PlayerRating(rating: 600, leagueRating: 600, matchesPlayed: 0);

  /// Колонки, которые надо запросить, чтобы собрать этот объект.
  /// Одна строка на весь проект — иначе где-нибудь забудется league_rating.
  static const String columns = 'rating, league_rating, matches_played';

  /// Строка из user_languages. Пустая строка (языковая пара ещё не
  /// заведена) — это новичок, а не ошибка.
  factory PlayerRating.fromRow(Map<String, dynamic>? row) {
    if (row == null) return newcomer;
    final r = (row['rating'] as num?)?.toDouble();
    if (r == null) return newcomer;
    // league_rating — зеркало, которое ведёт триггер. Если его вдруг нет в
    // выборке, округляем сами: в Эло это ровно то же число, в отличие от
    // Glicko-2, где такая подстановка подняла бы игрока на лигу-две вверх.
    final lr = (row['league_rating'] as num?)?.toDouble() ?? r;
    return PlayerRating(
      rating: r,
      leagueRating: lr.round(),
      matchesPlayed: (row['matches_played'] as num?)?.toInt() ?? 0,
    );
  }

  /// То, что показывается игроку как «рейтинг».
  int get display => rating.round();

  League get league => leagueFor(leagueRating);
  int get levelIndex => leagueIndexForRating(leagueRating);

  /// Прогресс внутри лиги, 0..1.
  ///
  /// В верхней лиге полоса заполнена целиком. Её «потолок» — условные
  /// 999999, и честная доля от него держала бы алмазного игрока на почти
  /// пустой полосе вечно, хотя выше подниматься уже некуда.
  double get bandProgress {
    if (toNextLeague == null) return 1;
    final span = league.max - league.min;
    if (span <= 0) return 1;
    return ((leagueRating - league.min) / span).clamp(0.0, 1.0);
  }

  /// Сколько осталось до следующей лиги. null — выше некуда.
  int? get toNextLeague =>
      league.max > 90000 ? null : league.max - leagueRating;

  /// Система ещё не откалибровала игрока: первые десять матчей рейтинг
  /// ходит вдвое быстрее обычного (K = 40), и честнее пометить его как
  /// предварительный, чем делать вид, что это уже устоявшееся число.
  /// Тот же порог, что в public.elo_k.
  bool get isProvisional => matchesPlayed < calibrationMatches;

  /// Столько матчей идут с повышенным K — граница калибровки.
  static const int calibrationMatches = 10;

  /// Цена одного матча (K). Копия лестницы из public.elo_k: 40 на
  /// калибровке, 10 в Алмазе, 20 в остальных случаях.
  double get kFactor {
    if (matchesPlayed < calibrationMatches) return 40;
    if (rating >= 2400) return 10;
    return 20;
  }

  /// Примерно столько очков принесёт победа над равным соперником — «±N»
  /// в карточках режимов.
  ///
  /// Против равного ожидание E = 0.5, поэтому изменение = K * (1 - 0.5) =
  /// K/2. Против сильного или слабого будет иначе, но соперника на момент
  /// показа карточки ещё нет.
  int get estimatedSwing => (kFactor / 2).round();
}
