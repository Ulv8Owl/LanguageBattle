import '../core/word_packs.dart';
import 'remote_content.dart';

/// Одно слово-карточка: одно и то же понятие, параллельный перевод на все
/// языки, для которых оно переведено.
///
/// РАНЬШЕ здесь были три фиксированных поля (ru/en/es); см. тот же переход
/// в PhraseEntry (phrase_bank.dart) — причина и инвариант («весь уровень
/// переведён на язык, или ни одной карточки») одинаковы для обоих банков.
class FlashcardEntry {
  final Map<String, String> byLanguage;

  const FlashcardEntry(this.byLanguage);

  factory FlashcardEntry.fromJson(Map<String, dynamic> json) =>
      FlashcardEntry(json.map((key, value) => MapEntry(key, value as String)));

  /// null — для этого языка уровень ещё не переведён.
  String? forLanguage(String languageCode) => byLanguage[languageCode];
}

/// Банк слов для режима «Тренировка» — 6 уровней (по числу лиг) × 1000 слов
/// каждый.
///
/// Источник — RemoteContent: тот же JSON, что раньше лежал бандлом в
/// assets/vocab, теперь тянется с гита в рантайме и кэшируется на диске.
/// Формат каждого файла: плоский JSON-массив из 1000 объектов в
/// фиксированном порядке (индекс в массиве = глобальный word_index,
/// используемый в mark_word_learned/user_learned_words) — не изменился.
class FlashcardBank {
  FlashcardBank._();

  static final Map<int, List<FlashcardEntry>> _cache = {};

  static String _repoPath(int levelIndex) => 'assets/vocab/words_${wordLevelSlugs[levelIndex]}.json';

  /// Все 1000 слов уровня [levelIndex] (0..5), с кэшем на процесс — уровень
  /// не меняется каждую карточку, незачем перечитывать его заново.
  static Future<List<FlashcardEntry>> loadLevel(int levelIndex) async {
    final cached = _cache[levelIndex];
    if (cached != null) return cached;

    final decoded = await RemoteContent.loadJson(_repoPath(levelIndex));
    final entries = (decoded as List)
        .map((e) => FlashcardEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);
    _cache[levelIndex] = entries;
    return entries;
  }

  /// Переведён ли словарь уровня [levelIndex] на язык [languageCode].
  /// Уровень должен быть уже загружен (loadLevel).
  static bool hasContentFor(int levelIndex, String languageCode) {
    final entries = _cache[levelIndex];
    if (entries == null || entries.isEmpty) return false;
    return entries.first.byLanguage.containsKey(languageCode);
  }

  /// 100 слов пака [packIndex] (0..9) из уже загруженного уровня.
  static List<FlashcardEntry> packSlice(List<FlashcardEntry> levelWords, int packIndex) {
    final start = packIndex * wordsPerPack;
    return levelWords.sublist(start, start + wordsPerPack);
  }
}
