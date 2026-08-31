import 'dart:math';

import '../core/leagues.dart';
import '../core/word_packs.dart';

/// Рейтинг игрока по Glicko-2 — ровно то, что лежит в user_languages.
///
/// Glicko-2 хранит про игрока не одно число, а три:
///  * [rating] — сама оценка силы (старт 1500);
///  * [deviation] (RD) — насколько система в этой оценке уверена
///    (350 у новичка, ~50 у того, кто играет постоянно);
///  * волатильность — насколько нестабильны его результаты; клиенту она
///    не нужна и здесь её нет, ей распоряжается только SQL.
///
/// Разделение [rating] и [leagueRating] — главное, ради чего этот класс
/// существует. Игроку показывается сам рейтинг: это его результат, и он
/// не должен прыгать от того, что система в нём уверена или не уверена.
/// А вот лига, уровень CEFR, сложность фраз и доступ к наборам слов
/// считаются по КОНСЕРВАТИВНОЙ оценке rating - 2*RD: пока про игрока
/// ничего не известно, система не выдаёт ему материал верхних уровней и
/// не сажает его в высокую лигу авансом. Это стандартная для Glicko
/// рекомендация самого Гликмана для любых рейтинг-таблиц.
///
/// league_rating считает и хранит база (триггер trg_sync_rating_mirrors,
/// миграция 0023), клиент его только читает — чтобы лига на экране и лига
/// в проверках сервера не могли разойтись.
class PlayerRating {
  final double rating;
  final double deviation;
  final int leagueRating;

  const PlayerRating({
    required this.rating,
    required this.deviation,
    required this.leagueRating,
  });

  /// Новичок: 1500 ± 350 — стартовые значения Glicko-2.
  static const PlayerRating newcomer =
      PlayerRating(rating: 1500, deviation: 350, leagueRating: 800);

  /// Колонки, которые надо запросить, чтобы собрать этот объект.
  /// Одна строка на весь проект — иначе где-нибудь забудется league_rating.
  static const String columns = 'rating, rating_deviation, league_rating';

  /// Строка из user_languages. Пустая строка (языковая пара ещё не
  /// заведена) — это новичок, а не ошибка.
  factory PlayerRating.fromRow(Map<String, dynamic>? row) {
    if (row == null) return newcomer;
    final r = (row['rating'] as num?)?.toDouble();
    if (r == null) return newcomer;
    final rd = (row['rating_deviation'] as num?)?.toDouble() ??
        newcomer.deviation;
    // league_rating — зеркало, которое ведёт триггер. Если его вдруг нет
    // в выборке, пересчитываем по той же формуле, а не подставляем rating:
    // подстановка сырого рейтинга подняла бы игрока на лигу-две вверх.
    final lr = (row['league_rating'] as num?)?.toDouble() ?? (r - 2 * rd);
    return PlayerRating(
      rating: r,
      deviation: rd,
      leagueRating: lr.round(),
    );
  }

  /// То, что показывается игроку как «рейтинг».
  int get display => rating.round();

  /// Лига и уровень CEFR — по консервативной оценке.
  League get league => leagueFor(leagueRating);
  int get levelIndex => leagueIndexForRating(leagueRating);

  /// Прогресс внутри лиги, 0..1 — тоже по консервативной оценке, иначе
  /// полоска и подпись под ней считались бы по разным числам.
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

  /// Система ещё не уверена в оценке. Порог 150 — примерно две-три
  /// сыгранных партии: до этого рейтинг ходит десятками очков за матч, и
  /// честнее пометить его как предварительный, чем делать вид, что это
  /// уже устоявшееся число.
  bool get isProvisional => deviation > 150;

  /// Примерно столько очков принесёт победа над равным соперником — «±N»
  /// в карточках режимов.
  ///
  /// В эло эта цифра была константой (K/2), и её можно было написать в
  /// вёрстке руками. В Glicko-2 её нет: за матч меняется тем больше, чем
  /// меньше система уверена в игроке, — у новичка это ~160 очков, у
  /// наигранного ~7. Поэтому считаем прямо здесь, теми же формулами, что
  /// в SQL (glicko2_update), для симметричного случая: равный рейтинг и
  /// такое же RD у соперника.
  ///
  /// Вывод формулы. При равных рейтингах E = 0.5, поэтому
  ///   v = 1 / (g^2 * 0.25),  phi' = 1 / sqrt(1/(phi^2 + sigma^2) + 1/v),
  ///   изменение = phi'^2 * g * 0.5 * 173.7178.
  /// Волатильность здесь берём типовую (0.06): на один матч она сдвигается
  /// в четвёртом знаке и на «примерно» не влияет.
  int get estimatedSwing {
    const scale = 173.7178;
    const sigma = 0.06;
    final phi = deviation / scale;
    final g = 1 / sqrt(1 + 3 * phi * phi / (pi * pi));
    final v = 1 / (g * g * 0.25);
    final phiStar2 = phi * phi + sigma * sigma;
    final phiNew2 = 1 / (1 / phiStar2 + 1 / v);
    return (phiNew2 * g * 0.5 * scale).round();
  }
}
