/// Уровни CEFR, которые игрок выбирает при регистрации, и стартовый
/// рейтинг каждого.
///
/// Клиентская копия таблицы public.rating_for_cefr_level (миграция 0028).
/// Совпадение проверяется тестом test/cefr_levels_test.dart, который читает
/// саму миграцию — иначе две таблицы разошлись бы при первой же правке, и
/// игрок, выбравший B1, оказался бы не там, где написано на экране.
///
/// Стартовый рейтинг уровня — НАЧАЛО его лиги, кроме A1: Олово занимает
/// 0..1200, и «начальный» игрок не должен стоять рядом с тем, кто языка не
/// знает вовсе, поэтому A1 — середина Олова.
///
/// Названия уровней НЕ здесь: они зависят от языка интерфейса и живут в
/// AppStrings.levelName (ru: «Средний», en: «Intermediate»). Здесь только
/// то, что от языка не зависит — код и число.
class CefrLevel {
  /// Код уровня в нижнем регистре: a0, a1, ... c2. В таком же виде уходит
  /// в set_placement_rating.
  final String code;

  /// Рейтинг, с которого игрок начнёт, если подтвердит этот уровень.
  final int startingRating;

  /// Индекс уровня в банке фраз и слов (PhraseBank/FlashcardBank), он же
  /// индекс лиги. A0 и A1 делят нулевой уровень: отдельного банка фраз
  /// «для тех, кто не знает ни слова» нет, и проверка для них идёт по A1.
  final int contentLevelIndex;

  const CefrLevel({
    required this.code,
    required this.startingRating,
    required this.contentLevelIndex,
  });

  /// Как уровень пишется в подписях: A0, B2 и т.д.
  String get label => code.toUpperCase();
}

const List<CefrLevel> cefrLevels = [
  CefrLevel(code: 'a0', startingRating: 0, contentLevelIndex: 0),
  CefrLevel(code: 'a1', startingRating: 600, contentLevelIndex: 0),
  CefrLevel(code: 'a2', startingRating: 1200, contentLevelIndex: 1),
  CefrLevel(code: 'b1', startingRating: 1500, contentLevelIndex: 2),
  CefrLevel(code: 'b2', startingRating: 1800, contentLevelIndex: 3),
  CefrLevel(code: 'c1', startingRating: 2100, contentLevelIndex: 4),
  CefrLevel(code: 'c2', startingRating: 2400, contentLevelIndex: 5),
];

CefrLevel? cefrLevelByCode(String code) {
  for (final level in cefrLevels) {
    if (level.code == code.toLowerCase()) return level;
  }
  return null;
}

/// Доля правильных ответов, при которой проверка считается сданной.
///
/// Балл судьи за раунд — 1..10, поэтому «правильно ответил» = средний балл
/// не ниже 6 из 10. Порог один и тот же на всех уровнях: он про то,
/// справился ли игрок с материалом СВОЕГО уровня, а не про то, насколько
/// уровень сложен.
const double placementPassRatio = 0.6;
