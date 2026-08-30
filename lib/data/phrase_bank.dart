import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

import '../core/word_packs.dart';

/// Один пункт банка фраз: одна и та же мысль на трёх языках (RU/EN/ES),
/// параллельный перевод.
class PhraseEntry {
  final String ru;
  final String en;
  final String es;

  const PhraseEntry({required this.ru, required this.en, required this.es});

  factory PhraseEntry.fromJson(Map<String, dynamic> json) => PhraseEntry(
        ru: json['ru'] as String,
        en: json['en'] as String,
        es: json['es'] as String,
      );

  String forLanguage(String languageCode) {
    switch (languageCode) {
      case 'ru':
        return ru;
      case 'es':
        return es;
      case 'en':
      default:
        return en;
    }
  }
}

/// Банк фраз для раундов боя и Одиночной Игры — по 100 фраз на каждый из
/// шести уровней (A1..C2, они же лиги), ассеты
/// assets/phrases/phrases_a1.json .. phrases_c2.json.
///
/// ФРАЗЫ НЕ ГЕНЕРИРУЮТСЯ НЕЙРОСЕТЬЮ В РАНТАЙМЕ: LLM в приложении только
/// оценивает грамматику и разбирает ошибки (раздел 9), выбор фразы раунда —
/// случайный выбор по этому фиксированному списку.
///
/// Фразы РАЗНЫЕ ДЛЯ РАЗНЫХ ЛИГ: в Медной лиге простое настоящее время и
/// бытовая лексика, в Лиге Мастеров — сложный синтаксис и идиоматика.
/// Раньше список был общим и состоял из десяти текстов, у которых второе
/// предложение вообще совпадало дословно, так что игрок каждый раунд
/// переводил одну и ту же фразу про свежие продукты.
///
/// Индекс фразы СКВОЗНОЙ (0..599): уровень = index ~/ 100. Так он влезает
/// в один столбец rounds.phrase_index и не требует хранить уровень отдельно.
class PhraseBank {
  PhraseBank._();

  static const int perLevel = 100;

  static final Random _random = Random();
  static final Map<int, List<PhraseEntry>> _cache = {};

  /// Фразы уровня [levelIndex] (0..5). Уровень грузится один раз на процесс.
  static Future<List<PhraseEntry>> loadLevel(int levelIndex) async {
    final level = levelIndex.clamp(0, wordLevelSlugs.length - 1);
    final cached = _cache[level];
    if (cached != null) return cached;

    final raw = await rootBundle.loadString('assets/phrases/phrases_${wordLevelSlugs[level]}.json');
    final entries = (jsonDecode(raw) as List)
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
