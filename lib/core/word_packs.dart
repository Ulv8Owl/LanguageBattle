import 'leagues.dart';
import 'supabase_client.dart';

/// 6 уровней банка слов Тренировки = 6 лиг (см. supabase/migrations/0010):
/// Медная->A1 ... Мастеров->C2. Порядок и число ДОЛЖНЫ совпадать с
/// leagueBands в leagues.dart и с league_index_for_rating в SQL.
const List<String> wordLevelSlugs = ['a1', 'a2', 'b1', 'b2', 'c1', 'c2'];

const int wordsPerLevel = 1000;
const int packsPerLevel = 10;
const int wordsPerPack = 100;

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

/// Один набор из 100 слов: цена, владение, доступность по лиге — всё
/// считается на сервере (list_word_packs RPC), клиент только отображает.
class WordPackInfo {
  final int levelIndex;
  final int packIndex;
  final int price;
  final bool owned;
  final bool leagueLocked;

  const WordPackInfo({
    required this.levelIndex,
    required this.packIndex,
    required this.price,
    required this.owned,
    required this.leagueLocked,
  });

  /// "1–100", "101–200" и т.д.
  String get rangeLabel {
    final from = packIndex * wordsPerPack + 1;
    final to = (packIndex + 1) * wordsPerPack;
    return '$from–$to';
  }

  factory WordPackInfo.fromJson(Map<String, dynamic> json) {
    return WordPackInfo(
      levelIndex: (json['level_index'] as num).toInt(),
      packIndex: (json['pack_index'] as num).toInt(),
      price: (json['price'] as num).toInt(),
      owned: json['owned'] as bool? ?? false,
      leagueLocked: json['league_locked'] as bool? ?? false,
    );
  }
}

class WordPackCatalog {
  WordPackCatalog._();

  /// Все 60 наборов (6 уровней × 10) одним вызовом.
  static Future<List<WordPackInfo>> fetch() async {
    final rows = await supabase.rpc('list_word_packs');
    return (rows as List)
        .map((r) => WordPackInfo.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  static Future<void> purchase(int levelIndex, int packIndex) async {
    await supabase.rpc('purchase_word_pack', params: {
      'p_level_index': levelIndex,
      'p_pack_index': packIndex,
    });
  }

  /// Раз в жизни на слово — сервер сам не начисляет повторно, но клиенту
  /// не нужно самому это проверять: просто дёргаем RPC при каждом "Знаю".
  /// [globalWordIndex] — индекс слова 0..999 внутри уровня (не внутри пака).
  static Future<int> markLearned(int levelIndex, int globalWordIndex) async {
    final result = await supabase.rpc('mark_word_learned', params: {
      'p_level_index': levelIndex,
      'p_word_index': globalWordIndex,
    });
    if (result is Map) {
      return (result['coins'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }
}
