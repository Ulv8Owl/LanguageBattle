import 'dart:math';

import '../core/word_packs.dart';
import 'remote_content.dart';

/// Кусок фразы, по которому игрок может тыкнуть.
///
/// [lead] — то, что стоит перед словами элемента и элементом НЕ является:
/// точка предыдущего предложения, запятая, пробел. Хранится отдельно,
/// потому что переворачиваться на другой язык должны только слова: точка
/// в конце предыдущего предложения к этому элементу отношения не имеет, а
/// вместе с ним она мигала бы при каждом тапе.
///
/// Разделитель «|» из исходника (assets/cefr/*.txt) сюда не попадает
/// вообще — он служебный и игроку не показывается ни разу.
class PhraseElement {
  final String lead;
  final String text;

  const PhraseElement({required this.lead, required this.text});

  factory PhraseElement.fromJson(Map<String, dynamic> json) => PhraseElement(
        lead: json['lead'] as String? ?? '',
        text: json['text'] as String? ?? '',
      );
}

/// Одна фраза раунда: одна и та же мысль на всех языках, разбитая на
/// элементы, плюс пояснение к каждому элементу.
///
/// ИНВАРИАНТ, который держит сборщик (tools/build_cefr.py) и проверяет
/// assets/cefr/validate.py: число элементов в строке ОДИНАКОВО во всех
/// языках, и элемент N везде покрывает один и тот же смысловой кусок.
/// На этом стоит вся механика подсказок: тапнув по третьему элементу
/// родной фразы, игрок обязан увидеть именно третий элемент изучаемой.
class PhraseEntry {
  final Map<String, List<PhraseElement>> elementsByLanguage;

  /// Хвост строки после последнего элемента — обычно точка.
  final Map<String, String> tailByLanguage;

  final Map<String, List<String>> explanationsByLanguage;

  const PhraseEntry({
    required this.elementsByLanguage,
    required this.tailByLanguage,
    required this.explanationsByLanguage,
  });

  factory PhraseEntry.fromJson(Map<String, dynamic> json) {
    Map<String, List<T>> byLang<T>(String key, T Function(dynamic) parse) {
      final raw = json[key] as Map<String, dynamic>? ?? const {};
      return raw.map((lang, list) =>
          MapEntry(lang, (list as List).map(parse).toList(growable: false)));
    }

    return PhraseEntry(
      elementsByLanguage: byLang(
        'elements',
        (e) => PhraseElement.fromJson(Map<String, dynamic>.from(e as Map)),
      ),
      tailByLanguage: (json['tail'] as Map<String, dynamic>? ?? const {})
          .map((lang, value) => MapEntry(lang, value as String)),
      explanationsByLanguage: byLang('explanations', (e) => e as String),
    );
  }

  /// Элементы на языке [languageCode]. Пустой список — этого языка в
  /// банке нет (см. hasContentFor: до раунда дело в таком случае не
  /// доходит).
  List<PhraseElement> elementsFor(String languageCode) =>
      elementsByLanguage[languageCode] ?? const [];

  String tailFor(String languageCode) => tailByLanguage[languageCode] ?? '';

  /// Пояснение к элементу [index] (с нуля) на языке [languageCode].
  String? explanationFor(String languageCode, int index) {
    final list = explanationsByLanguage[languageCode];
    if (list == null || index < 0 || index >= list.length) return null;
    return list[index];
  }

  /// Фраза целиком, как её видит игрок: без «|» и без служебных пометок.
  String? forLanguage(String languageCode) {
    final elements = elementsByLanguage[languageCode];
    if (elements == null || elements.isEmpty) return null;
    final buffer = StringBuffer();
    for (final e in elements) {
      buffer.write(e.lead);
      buffer.write(e.text);
    }
    buffer.write(tailFor(languageCode));
    return buffer.toString();
  }

  /// Та же фраза, но с «|» после каждого элемента.
  ///
  /// Уходит на сервер в training_rounds.generated_phrase / rounds.
  /// generated_phrase: воркер оценивает ответ поэлементно и должен знать
  /// те же границы, что видел игрок. Клиент границы не пересчитывает и
  /// серверу не диктует — обе стороны читают одну строку.
  String? markedForLanguage(String languageCode) {
    final elements = elementsByLanguage[languageCode];
    if (elements == null || elements.isEmpty) return null;
    final buffer = StringBuffer();
    for (final e in elements) {
      buffer.write(e.lead);
      buffer.write(e.text);
      buffer.write('|');
    }
    buffer.write(tailFor(languageCode));
    return buffer.toString();
  }

  int elementCount(String languageCode) => elementsFor(languageCode).length;

  /// Смещение начала каждого элемента в ЧИСТОЙ фразе (той, что без «|»).
  ///
  /// Считается ровно так же, как на сервере (parseElements в
  /// _shared/elementScoring.ts): сумма длин всех предыдущих lead и text.
  /// Совпадение обязательно — сервер присылает непроизнесённые элементы
  /// именно смещениями, и по ним клиент находит, какой элемент подсветить.
  List<int> elementOffsets(String languageCode) {
    final elements = elementsFor(languageCode);
    final offsets = <int>[];
    var offset = 0;
    for (final e in elements) {
      offset += e.lead.length;
      offsets.add(offset);
      offset += e.text.length;
    }
    return offsets;
  }
}

/// Банк фраз для раундов боя и Одиночной Игры.
///
/// Источник — датасет assets/cefr (36 текстовых файлов), собранный в
/// assets/phrases/cefr_<уровень>.json скриптом tools/build_cefr.py.
/// Формат исходника и правила его расширения — в assets/cefr/README.md.
///
/// ФРАЗ НА УРОВЕНЬ — ДЕСЯТЬ, а не сто, как было у прежнего банка. Это
/// сознательный размен: каждая фраза теперь несёт разбиение на элементы и
/// пояснение к КАЖДОМУ элементу на трёх языках, то есть на порядок больше
/// вычитанного вручную текста. Десять фраз × 21 элемент на C2 — это 210
/// пояснений на язык только для одного уровня.
///
/// ФРАЗЫ НЕ ГЕНЕРИРУЮТСЯ НЕЙРОСЕТЬЮ В РАНТАЙМЕ: выбор фразы раунда —
/// случайный выбор по этому фиксированному списку.
///
/// Индекс фразы СКВОЗНОЙ (0..59): уровень = index ~/ perLevel. Так он
/// влезает в один столбец rounds.phrase_index и не требует хранить
/// уровень отдельно.
class PhraseBank {
  PhraseBank._();

  /// Сколько фраз в уровне. Было 100 у прежнего банка — см. комментарий
  /// класса о том, почему стало 10.
  static const int perLevel = 10;

  static final Random _random = Random();
  static final Map<int, List<PhraseEntry>> _cache = {};

  static String _repoPath(int level) => 'assets/phrases/cefr_${wordLevelSlugs[level]}.json';

  /// Фразы уровня [levelIndex] (0..5). Уровень грузится один раз на процесс.
  ///
  /// Бросает [ContentUnavailable], если файл в принципе недостижим (сеть,
  /// диск и бандл — все три источника отказали).
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
  /// без переведённых фраз раунд физически не собрать: не из чего показать
  /// задание или не с чем сравнить ответ.
  static bool hasContentFor(int levelIndex, String languageA, String languageB) {
    final entries = _cache[levelIndex];
    if (entries == null || entries.isEmpty) return false;
    // Инвариант «весь уровень или ничего» позволяет проверить одну фразу,
    // а не все десять.
    final sample = entries.first;
    return sample.elementsFor(languageA).isNotEmpty &&
        sample.elementsFor(languageB).isNotEmpty;
  }

  /// Сквозной индекс случайной фразы уровня, кроме уже сыгранных.
  ///
  /// Если исключено всё — начинаем круг заново: лучше повтор, чем раунд без
  /// фразы. При десяти фразах на уровень и десяти раундах в матче круг
  /// закрывается ровно за матч, поэтому это уже не теория.
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
  /// иначе вернётся null, а не исключение посреди раунда.
  static PhraseEntry? entry(int globalIndex) {
    final level = globalIndex ~/ perLevel;
    final within = globalIndex % perLevel;
    final entries = _cache[level];
    if (entries == null || within >= entries.length) return null;
    return entries[within];
  }

  /// Фраза целиком, как её видит игрок (без «|»).
  static String textFor(int globalIndex, String languageCode) =>
      entry(globalIndex)?.forLanguage(languageCode) ?? '';

  /// Фраза с «|» — то, что уходит на сервер как эталон ответа.
  static String markedTextFor(int globalIndex, String languageCode) =>
      entry(globalIndex)?.markedForLanguage(languageCode) ?? '';

  static List<PhraseElement> elementsFor(int globalIndex, String languageCode) =>
      entry(globalIndex)?.elementsFor(languageCode) ?? const [];
}
