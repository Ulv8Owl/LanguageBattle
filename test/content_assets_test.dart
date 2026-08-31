import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Проверки самих данных, а не кода: 600 фраз и 6000 слов правились
/// скриптами, и молча испортить их куда проще, чем заметить это на экране.
void main() {
  const levels = ['a1', 'a2', 'b1', 'b2', 'c1', 'c2'];

  List<Map<String, dynamic>> read(String path) =>
      (jsonDecode(File(path).readAsStringSync()) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  test('в каждом уровне ровно 100 фраз на трёх языках', () {
    for (final level in levels) {
      final phrases = read('assets/phrases/phrases_$level.json');
      expect(phrases.length, 100, reason: level);
      for (final p in phrases) {
        for (final lang in ['en', 'ru', 'es']) {
          expect((p[lang] as String).trim(), isNotEmpty, reason: '$level/$lang');
        }
      }
    }
  });

  test('фразы не повторяются между уровнями', () {
    final all = <String>[];
    for (final level in levels) {
      all.addAll(read('assets/phrases/phrases_$level.json').map((p) => p['en'] as String));
    }
    expect(all.length, 600);
    expect(all.toSet().length, 600, reason: 'дубликаты фраз');
  });

  test('второе предложение у фраз своё, а не общее', () {
    // Прежний банк состоял из десяти текстов, у которых второе предложение
    // совпадало дословно: игрок каждый раунд переводил одно и то же.
    final seconds = <String>[];
    for (final level in levels) {
      for (final p in read('assets/phrases/phrases_$level.json')) {
        seconds.add((p['en'] as String).split('. ').last);
      }
    }
    expect(seconds.toSet().length, seconds.length, reason: 'повторяются хвосты фраз');
  });

  test('в каждом уровне ровно 1000 слов с непустыми переводами', () {
    for (final level in levels) {
      final words = read('assets/vocab/words_$level.json');
      expect(words.length, 1000, reason: level);
      for (final w in words) {
        for (final lang in ['en', 'ru', 'es']) {
          expect((w[lang] as String).trim(), isNotEmpty, reason: '$level/$lang');
        }
      }
    }
  });

  test('слова не повторяются во всём банке', () {
    final all = <String>[];
    for (final level in levels) {
      all.addAll(read('assets/vocab/words_$level.json').map((w) => (w['en'] as String).toLowerCase()));
    }
    expect(all.length, 6000);
    expect(all.toSet().length, 6000, reason: 'дубликаты слов');
  });

  test('любой язык сверх en/ru/es переведён либо во ВСЕХ пунктах уровня, либо ни в одном', () {
    // PhraseBank/FlashcardBank проверяют доступность языка по ОДНОМУ пункту
    // (см. hasContentFor) — это дёшево, но полагается на то, что контент
    // никогда не бывает переведён наполовину. Здесь эта гарантия
    // проверяется по-настоящему, по всем ста/тысяче пунктам, а не по
    // одному: наполовину переведённый уровень пройдёт мимо ручной проверки,
    // но не мимо этого теста.
    for (final level in levels) {
      for (final MapEntry(key: file, value: expectedCount) in {
        'assets/phrases/phrases_$level.json': 100,
        'assets/vocab/words_$level.json': 1000,
      }.entries) {
        final items = read(file);
        final extraLanguages = items
            .expand((item) => item.keys)
            .where((k) => k != 'en' && k != 'ru' && k != 'es')
            .toSet();
        for (final lang in extraLanguages) {
          final withLang = items.where((item) => (item[lang] as String?)?.trim().isNotEmpty ?? false);
          expect(withLang.length, expectedCount, reason: '$file/$lang: переведена не вся колода');
        }
      }
    }
  });

  test('первая колода уровня целиком собрана из его же фраз', () {
    // Ради этого весь словарь и пересобирался: колода, которую игрок
    // открывает первой, должна готовить ровно к тем фразам, что ему
    // выпадут в его лиге.
    for (final level in levels) {
      final text = read('assets/phrases/phrases_$level.json')
          .map((p) => (p['en'] as String).toLowerCase())
          .join(' ');
      final vocabulary = text.split(RegExp(r"[^a-z']+")).toSet();
      final firstPack = read('assets/vocab/words_$level.json').take(100);
      final fromPhrases = firstPack.where((w) => vocabulary.contains((w['en'] as String).toLowerCase()));
      expect(fromPhrases.length, 100, reason: '$level: первый пак должен быть из фраз уровня');
    }
  });
}
