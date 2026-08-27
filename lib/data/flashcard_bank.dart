import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../core/word_packs.dart';

/// Одно слово-карточка: одно и то же понятие на трёх языках (RU/EN/ES).
class FlashcardEntry {
  final String ru;
  final String en;
  final String es;

  const FlashcardEntry({required this.ru, required this.en, required this.es});

  factory FlashcardEntry.fromJson(Map<String, dynamic> json) {
    return FlashcardEntry(
      ru: json['ru'] as String,
      en: json['en'] as String,
      es: json['es'] as String,
    );
  }

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

/// Банк слов для режима «Тренировка» — 6 уровней (по числу лиг) × 1000 слов
/// каждый, статичные ассеты assets/vocab/words_a1.json..c2.json. Уровень
/// целиком грузится один раз и режется на паки по 100 слов на клиенте —
/// формат каждого файла: плоский JSON-массив из 1000 объектов {ru,en,es} в
/// фиксированном порядке (индекс в массиве = глобальный word_index,
/// используемый в mark_word_learned/user_learned_words).
class FlashcardBank {
  FlashcardBank._();

  static final Map<int, List<FlashcardEntry>> _cache = {};

  /// Все 1000 слов уровня [levelIndex] (0..5), с кэшем на процесс — уровень
  /// не меняется каждую карточку, незачем перечитывать ассет.
  static Future<List<FlashcardEntry>> loadLevel(int levelIndex) async {
    final cached = _cache[levelIndex];
    if (cached != null) return cached;

    final slug = wordLevelSlugs[levelIndex];
    final raw = await rootBundle.loadString('assets/vocab/words_$slug.json');
    final decoded = jsonDecode(raw) as List;
    final entries = decoded
        .map((e) => FlashcardEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);
    _cache[levelIndex] = entries;
    return entries;
  }

  /// 100 слов пака [packIndex] (0..9) из уже загруженного уровня.
  static List<FlashcardEntry> packSlice(List<FlashcardEntry> levelWords, int packIndex) {
    final start = packIndex * wordsPerPack;
    return levelWords.sublist(start, start + wordsPerPack);
  }
}
