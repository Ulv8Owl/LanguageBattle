/// Пословные переводы фраз — то, из чего Тренировка делает карточки.
///
/// ЗАЧЕМ ОТДЕЛЬНО ОТ ЭЛЕМЕНТОВ. Элемент это кусок смысла («в семь» ↔
/// "at seven"), и подсказке в Одиночной Игре его хватает. В Тренировке
/// игрок отмечает слова, которых НЕ ЗНАЕТ, и элементом тут не обойтись:
/// не знать можно «семь», прекрасно зная «в». Поэтому здесь у каждого
/// слова свой перевод, а элемент остаётся тем, что держит контекст.
///
/// ЕСЛИ ГЛОССАРИЯ НА УРОВЕНЬ НЕТ — ЭТО НЕ ПОЛОМКА. Тогда каждое слово
/// элемента получает перевод ЭЛЕМЕНТА ЦЕЛИКОМ: грубее, чем хотелось бы,
/// но Тренировка работает на всех шести уровнях с первого дня, а не
/// только там, где датасет уже дописан. Готовность видна в отладке
/// (`PhraseGlossary.isExact`).
///
/// СЛОВО РЕЖЕТСЯ ТЕМ ЖЕ ВЫРАЖЕНИЕМ, что и в сборщике
/// (tools/build_glossary.py). Две разные нарезки означали бы, что
/// подсветка на экране и перевод в карточке говорят о разных словах.
library;

import 'remote_content.dart';

/// Одно слово фразы и его перевод.
class GlossedWord {
  /// Слово, как оно стоит во фразе на родном языке.
  final String word;

  /// Перевод на изучаемый язык — он же лицевая сторона карточки.
  final String translation;

  /// Элемент, внутри которого стоит слово, — контекст для карточки.
  final String context;

  const GlossedWord({
    required this.word,
    required this.translation,
    required this.context,
  });

  /// Ключ, по которому слово узнаётся между фразами: одно и то же слово в
  /// одном и том же смысле не должно попасть в колоду дважды.
  String get key => '${word.toLowerCase()}→${translation.toLowerCase()}';
}

class PhraseGlossary {
  PhraseGlossary._();

  /// Как режется слово.
  ///
  /// ЗНАЧИТ ТО ЖЕ, ЧТО WORD_RE В tools/build_glossary.py, но записано
  /// иначе: у Python `\w` с флагом UNICODE знает про кириллицу, а у Dart
  /// (как и у JavaScript) `\w` навсегда остаётся латиницей, и на «Я встаю»
  /// такое выражение не нашло бы ни одного слова. Поэтому здесь буквы
  /// названы прямо — свойством Unicode.
  ///
  /// РАСХОЖДЕНИЕ ДВУХ НАРЕЗОК НЕ МОЛЧАЛИВО. Слова из файла сверяются со
  /// словами элемента перед тем, как их показать (см. usable ниже): не
  /// сошлись — берём запасной вариант, а не подставляем перевод не к тому
  /// слову.
  static final RegExp wordPattern =
      RegExp(r"\p{L}+(?:['’\-]\p{L}+)*|\d+", unicode: true);

  static const List<String> _levelSlugs = ['a1', 'a2', 'b1', 'b2', 'c1', 'c2'];

  /// Загруженные глоссарии: ключ «уровень/родной-целевой».
  static final Map<String, List<List<List<List<String>>>>> _cache = {};

  /// Пары, для которых файла нет вовсе. Ходить за ним второй раз незачем:
  /// отсутствие — это состояние датасета, а не сбой сети.
  static final Set<String> _missing = {};

  static String _key(int level, String native, String target) =>
      '$level/$native-$target';

  static String _repoPath(int level, String native, String target) =>
      'assets/phrases/gloss_${_levelSlugs[level]}_$native-$target.json';

  /// Есть ли пословный глоссарий для этой пары и уровня. false — слова
  /// получат перевод элемента целиком.
  static bool isExact(int level, String native, String target) =>
      _cache.containsKey(_key(level, native, target));

  /// Тянет глоссарий уровня. НИКОГДА НЕ БРОСАЕТ: нет файла — работаем на
  /// запасном варианте, и Тренировка от этого не останавливается.
  static Future<void> load(int level, String native, String target) async {
    final key = _key(level, native, target);
    if (_cache.containsKey(key) || _missing.contains(key)) return;
    try {
      final decoded = await RemoteContent.loadJson(_repoPath(level, native, target));
      _cache[key] = (decoded as List)
          .map((phrase) => (phrase as List)
              .map((element) => (element as List)
                  .map((pair) => (pair as List).map((v) => v as String).toList())
                  .toList())
              .toList())
          .toList();
    } catch (_) {
      _missing.add(key);
    }
  }

  /// Слова одного элемента с переводами.
  ///
  /// [nativeElement] и [targetElement] — текст одного и того же куска на
  /// двух языках; [phraseInLevel] — номер фразы внутри уровня (0..9).
  static List<GlossedWord> wordsOf({
    required int level,
    required String native,
    required String target,
    required int phraseInLevel,
    required int elementIndex,
    required String nativeElement,
    required String targetElement,
  }) {
    final words = wordPattern.allMatches(nativeElement).map((m) => m[0]!).toList();
    final exact = _cache[_key(level, native, target)];
    final pairs = exact != null &&
            phraseInLevel < exact.length &&
            elementIndex < exact[phraseInLevel].length
        ? exact[phraseInLevel][elementIndex]
        : null;

    // Слова из файла обязаны совпасть со словами элемента. Не совпали —
    // датасет разошёлся с фразами, и лучше запасной вариант, чем перевод,
    // подставленный не к тому слову: ему поверят.
    final usable = pairs != null &&
        pairs.length == words.length &&
        [for (var i = 0; i < words.length; i++) pairs[i][0] == words[i]].every((ok) => ok);

    return [
      for (var i = 0; i < words.length; i++)
        GlossedWord(
          word: words[i],
          translation: usable ? pairs[i][1] : targetElement,
          context: targetElement,
        ),
    ];
  }
}
