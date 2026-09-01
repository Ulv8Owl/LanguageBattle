import '../core/all_languages.dart';
import 'flashcard_bank.dart';
import 'phrase_bank.dart';

/// На каких языках УЖЕ можно играть, а какие только заявлены.
///
/// Разница принципиальна и стоила бы тупика, если её не показывать. Немец
/// выбирает Deutsch родным — и упирается в заглушку на каждом экране,
/// потому что фраза раунда показывается на РОДНОМ языке, а немецкого
/// перевода в банке ещё нет. Правильный ответ на это — не прятать язык из
/// списка (тогда человек решит, что игра его язык не поддерживает вовсе и
/// не вернётся), а честно написать «скоро» и не дать выбрать.
///
/// Готовность считается ПО САМОМУ КОНТЕНТУ, а не по списку в коде:
/// отдельный список рано или поздно соврёт — кто-то добавит переводы и
/// забудет его обновить, или наоборот. Язык готов, когда в банке A1 есть
/// и фразы, и слова: A1 — это то, с чего начинает любой новый игрок, и
/// без него играть нельзя вообще. Более высокие уровни подтянутся позже и
/// прикрыты своей проверкой (PhraseBank.hasContentFor на каждом входе в
/// режим).
class ContentLanguages {
  ContentLanguages._();

  static Set<String>? _cache;

  /// Языки из [allLanguages], на которых можно играть прямо сейчас.
  ///
  /// Никогда не бросает: если контент не скачался (нет сети на первом
  /// запуске), возвращает то, что известно наверняка, — набор языков,
  /// зашитый в бандл приложения. Пустой список здесь означал бы «выбрать
  /// нечего вообще», а это хуже, чем короткий список.
  static Future<Set<String>> ready() async {
    final cached = _cache;
    if (cached != null) return cached;

    try {
      final phrases = await PhraseBank.loadLevel(0);
      final words = await FlashcardBank.loadLevel(0);
      if (phrases.isEmpty || words.isEmpty) return _fallback;

      // Пересечение: язык готов, только если переведены И фразы, И слова.
      // Одни фразы без слов ломают Тренировку, одни слова без фраз — все
      // остальные режимы.
      final withPhrases = phrases.first.byLanguage.keys.toSet();
      final withWords = words.first.byLanguage.keys.toSet();
      final result = withPhrases.intersection(withWords).intersection(allLanguages.keys.toSet());
      _cache = result.isEmpty ? _fallback : result;
      return _cache!;
    } catch (_) {
      return _fallback;
    }
  }

  /// Что заведомо есть в бандле приложения — на случай, когда контент не
  /// удалось ни скачать, ни прочитать из кэша.
  static const Set<String> _fallback = {'en', 'ru', 'es'};
}
