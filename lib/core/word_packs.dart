import 'leagues.dart';


/// 6 уровней банка фраз и слов = 6 лиг (см. supabase/migrations/0010):
/// Медная->A1 ... Мастеров->C2. Порядок и число ДОЛЖНЫ совпадать с
/// leagueBands в leagues.dart и с league_index_for_rating в SQL.
const List<String> wordLevelSlugs = ['a1', 'a2', 'b1', 'b2', 'c1', 'c2'];

const int wordsPerLevel = 1000;

// НАБОРОВ СЛОВ БОЛЬШЕ НЕТ. Колода из ста слов, покупаемая в Магазине,
// ушла вместе со старой Тренировкой: слова теперь приходят из фразы
// раунда, и выбирает их сам игрок (см. FlashcardsScreen). Каталог,
// покупка и отметка выученного слова удалены и здесь, и на сервере
// (миграция 0051) — уровни остались только как имена файлов банка.

/// Индекс лиги (0..5) по КОНСЕРВАТИВНОЙ оценке рейтинга (league_rating =
/// rating - 2*RD) — тот же расчёт, что leagueFor в leagues.dart и
/// league_index_for_rating в SQL (миграция 0023). На вход идёт именно
/// league_rating, а не сам рейтинг: по этому индексу выдаются фразы и
/// наборы слов, и новичку не должен достаться материал C2 просто потому,
/// что он стартует с 1500.
int leagueIndexForRating(int leagueRating) {
  final league = leagueFor(leagueRating);
  final i = leagueBands.indexOf(league);
  return i < 0 ? 0 : i;
}
