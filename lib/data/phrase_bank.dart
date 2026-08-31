import 'dart:math';

import '../core/word_packs.dart';
import 'remote_content.dart';

/// Один пункт банка фраз: одна и та же мысль, параллельный перевод на все
/// языки, для которых он существует.
///
/// РАНЬШЕ здесь были три фиксированных поля (ru/en/es) — годилось, пока
/// языков было три. Теперь их до сотни, и добавление языка не должно
/// требовать правки этого класса: новый ключ в JSON — и всё.
///
/// ИНВАРИАНТ, которого держится контент (проверяется при генерации, не
/// кодом): в пределах одного уровня язык либо переведён ВО ВСЕХ 100
/// фразах, либо ни в одной. «Наполовину переведённый уровень» не
/// предусмотрен — это усложнило бы отбор случайной фразы (какую
/// подмножество можно давать этой паре?) ради случая, которого мы сами
/// себе не создаём.
class PhraseEntry {
  final Map<String, String> byLanguage;

  const PhraseEntry(this.byLanguage);

  factory PhraseEntry.fromJson(Map<String, dynamic> json) =>
      PhraseEntry(json.map((key, value) => MapEntry(key, value as String)));

  /// null — для этого языка фразы этого уровня ещё не переведены (см.
  /// инвариант выше — значит, не переведена ни одна во всём уровне).
  String? forLanguage(String languageCode) => byLanguage[languageCode];
}

/// Банк фраз для раундов боя и Одиночной Игры — по 100 фраз на каждый из
/// шести уровней (A1..C2, они же лиги).
///
/// Источник — RemoteContent (см. его же комментарий): тот же JSON, что
/// раньше лежал бандлом в assets/phrases, теперь тянется с гита в рантайме
/// и кэшируется на диске. Путь к репозиторию не изменился специально —
/// bundled-фолбэк в RemoteContent читает те же assets/phrases/*.json.
///
/// ФРАЗЫ НЕ ГЕНЕРИРУЮТСЯ НЕЙРОСЕТЬЮ В РАНТАЙМЕ: LLM в приложении только
/// оценивает грамматику и разбирает ошибки (раздел 9), выбор фразы раунда —
/// случайный выбор по этому фиксированному списку.
///
/// Фразы РАЗНЫЕ ДЛЯ РАЗНЫХ ЛИГ: в Медной лиге простое настоящее время и
/// бытовая лексика, в Лиге Мастеров — сложный синтаксис и идиоматика.
///
/// Индекс фразы СКВОЗНОЙ (0..599): уровень = index ~/ 100. Так он влезает
/// в один столбец rounds.phrase_index и не требует хранить уровень отдельно.
class PhraseBank {
  PhraseBank._();

  static const int perLevel = 100;

  static final Random _random = Random();
  static final Map<int, List<PhraseEntry>> _cache = {};

  static String _repoPath(int level) => 'assets/phrases/phrases_${wordLevelSlugs[level]}.json';

  /// Фразы уровня [levelIndex] (0..5). Уровень грузится один раз на процесс.
  ///
  /// Бросает [ContentUnavailable], если файл в принципе недостижим (сеть,
  /// диск и бандл — все три источника отказали). Для существующих шести
  /// уровней это не должно случаться на практике: бандл — гарантированная
  /// подстраховка.
  static Future<List<PhraseEntry>> loadLevel(int levelIndex) async {
    final level = levelIndex.clamp(0, wordLevelSlugs.length - 1);
    final cached = _cache[level];
    if (cached != null) return cached;

    final decoded = await RemoteContent.loadJson(_repoPath(level));
    final entries = (decoded as List)
        .map((e) => PhraseEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);
    _cache[level] = entries;
    return entries;
  }

  /// Загрузить сразу все уровни — нужно там, где в ленте встречаются фразы
  /// разных уровней (сыгранные раунды соперника в Дуэли).
  static Future<void> loadAll() async {
    for (var level = 0; level < wordLevelSlugs.length; level++) {
      await loadLevel(level);
    }
  }

  /// Переведён ли уровень [levelIndex] на ОБА языка пары — тот, на котором
  /// показывается задание, и тот, на который его нужно перевести. Уровень
  /// должен быть уже загружен (loadLevel/loadAll).
  ///
  /// Именно эта проверка стоит перед входом в Тренировку/Бой/Одиночную —
  /// без нативных 100 переведённых фраз раунд физически не собрать: не из
  /// чего показать задание или не с чем сравнить ответ.
  static bool hasContentFor(int levelIndex, String languageA, String languageB) {
    final entries = _cache[levelIndex];
    if (entries == null || entries.isEmpty) return false;
    // Инвариант «весь уровень или ничего» позволяет проверить один пункт,
    // а не все сто — см. комментарий у PhraseEntry.
    final sample = entries.first.byLanguage;
    return sample.containsKey(languageA) && sample.containsKey(languageB);
  }

  /// Сквозной индекс случайной фразы уровня, кроме уже сыгранных.
  ///
  /// Если исключено всё — начинаем круг заново: лучше повтор, чем раунд без
  /// фразы. Ста фраз хватает на десять матчей по десять раундов, так что на
  /// практике это не срабатывает.
  static int randomIndexForLevel(int levelIndex, {Set<int> exclude = const {}}) {
    final level = levelIndex.clamp(0, wordLevelSlugs.length - 1);
    final base = level * perLevel;
    final free = [
      for (var i = 0; i < perLevel; i++)
        if (!exclude.contains(base + i)) base + i,
    ];
    if (free.isEmpty) return base + _random.nextInt(perLevel);
    return free[_random.nextInt(free.length)];
  }

  /// Фраза по сквозному индексу. Уровень должен быть уже загружен —
  /// иначе вернётся пустая фраза, а не исключение посреди раунда.
  static PhraseEntry? entry(int globalIndex) {
    final level = globalIndex ~/ perLevel;
    final within = globalIndex % perLevel;
    final entries = _cache[level];
    if (entries == null || within >= entries.length) return null;
    return entries[within];
  }

  static String textFor(int globalIndex, String languageCode) =>
      entry(globalIndex)?.forLanguage(languageCode) ?? '';
}
