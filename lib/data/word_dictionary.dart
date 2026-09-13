import 'flashcard_bank.dart';

/// Двуязычный словарь поверх банка слов — им инструмент подставляет
/// переводы к притянутым субтитрам.
///
/// ПОЧЕМУ БАНК, А НЕ ПЕРЕВОДЧИК В СЕТИ. Субтитры приходят сразу целиком, и
/// ходить за переводом каждого слова в сеть — это сотни запросов на один
/// трек. Банк лежит на диске и отвечает мгновенно.
///
/// ЧЕГО В НЁМ НЕТ, ТО ОСТАЁТСЯ БЕЗ ПЕРЕВОДА. Банк знает шесть тысяч слов
/// уровней A1..C2 в словарной форме; имена собственные, редкие термины и
/// словоформы в него не попадают. Такое слово подсветится, но сверху под
/// ним будет пусто — и это честнее выдуманного перевода. Поправить его
/// можно там же, в разметке трека.
class WordDictionary {
  final Map<String, String> _byWord;

  const WordDictionary._(this._byWord);

  /// Слово без пунктуации и регистра. Субтитры приходят с запятыми и
  /// заглавной буквой в начале строки — без нормализации «Hello,» не
  /// нашлось бы в банке никогда.
  static String normalize(String word) {
    final letters = RegExp(r"[\p{L}\p{N}'’-]+", unicode: true);
    final matches = letters.allMatches(word.toLowerCase());
    if (matches.isEmpty) return '';
    return matches.map((m) => m.group(0)).join();
  }

  /// Словарь [from] -> [to] по всем шести уровням банка. Уровень, которого
  /// для этой пары нет, молча пропускается: половина словаря лучше, чем
  /// его отсутствие.
  static Future<WordDictionary> load({required String from, required String to}) async {
    final byWord = <String, String>{};
    for (var level = 0; level < 6; level++) {
      List<FlashcardEntry> entries;
      try {
        entries = await FlashcardBank.loadLevel(level);
      } catch (_) {
        continue;
      }
      for (final entry in entries) {
        final source = entry.forLanguage(from);
        final target = entry.forLanguage(to);
        if (source == null || target == null) continue;
        final key = normalize(source);
        if (key.isEmpty || target.trim().isEmpty) continue;
        // Первое вхождение выигрывает: уровни идут от простого к сложному,
        // и у многозначного слова останется самое ходовое значение.
        byWord.putIfAbsent(key, () => target.trim());
      }
    }
    return WordDictionary._(byWord);
  }

  String? translate(String word) {
    final key = normalize(word);
    return key.isEmpty ? null : _byWord[key];
  }
}
