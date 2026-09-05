import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Проверки самих данных, а не кода: банк фраз и 6000 слов собираются
/// скриптами, и молча испортить их куда проще, чем заметить это на экране.
///
/// ФРАЗЫ проверяются в собранном виде (assets/phrases/cefr_*.json). Формат
/// исходника (assets/cefr/*.txt) отдельно проверяет assets/cefr/validate.py,
/// а здесь — то, что из него собралось: именно это читает приложение.
void main() {
  const levels = ['a1', 'a2', 'b1', 'b2', 'c1', 'c2'];
  const languages = ['en', 'ru', 'es'];

  /// Сколько элементов во фразе каждого уровня: три на предложение,
  /// предложений — по уровню (A1: 2 → 6, C2: 7 → 21).
  const elementsPerLevel = {'a1': 6, 'a2': 9, 'b1': 12, 'b2': 15, 'c1': 18, 'c2': 21};

  List<Map<String, dynamic>> read(String path) =>
      (jsonDecode(File(path).readAsStringSync()) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> elementsOf(Map<String, dynamic> phrase, String lang) =>
      ((phrase['elements'] as Map)[lang] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  test('в каждом уровне 10 фраз на трёх языках', () {
    for (final level in levels) {
      final phrases = read('assets/phrases/cefr_$level.json');
      expect(phrases.length, 10, reason: level);
      for (final p in phrases) {
        for (final lang in languages) {
          expect(elementsOf(p, lang), isNotEmpty, reason: '$level/$lang');
        }
      }
    }
  });

  test('число элементов совпадает с уровнем и одинаково во всех языках', () {
    // На этом стоит вся механика подсказок: тапнув по третьему элементу
    // родной фразы, игрок обязан увидеть третий элемент изучаемой. Если
    // разбиение разъедется хотя бы в одной строке, подсказка покажет
    // чужой кусок — и заметить это на экране почти невозможно.
    for (final level in levels) {
      final phrases = read('assets/phrases/cefr_$level.json');
      for (var i = 0; i < phrases.length; i++) {
        for (final lang in languages) {
          expect(elementsOf(phrases[i], lang).length, elementsPerLevel[level],
              reason: '$level, фраза ${i + 1}, $lang');
        }
      }
    }
  });

  test('готовых пояснений в банке нет', () {
    // Разбор ошибок пишет модель по факту ответа игрока
    // (_shared/explainElements.ts). Заранее написанный текст сюда
    // вернуться не должен: он про РОДНУЮ формулировку и не знает, что
    // игрок сказал, — а выглядит на экране точно так же, из-за чего
    // молчание модели однажды уже прошло незамеченным.
    for (final level in levels) {
      for (final p in read('assets/phrases/cefr_$level.json')) {
        expect(p.containsKey('explanations'), isFalse, reason: level);
      }
    }
  });

  test('в собранных фразах не осталось служебного разделителя', () {
    // «|» разделяет элементы в ИСХОДНИКЕ и не должен доехать ни до одного
    // текста, который увидит игрок.
    for (final level in levels) {
      for (final p in read('assets/phrases/cefr_$level.json')) {
        for (final lang in languages) {
          for (final e in elementsOf(p, lang)) {
            expect(e['text'] as String, isNot(contains('|')), reason: level);
            expect(e['lead'] as String, isNot(contains('|')), reason: level);
          }
          expect((p['tail'] as Map)[lang] as String, isNot(contains('|')), reason: level);
        }
      }
    }
  });

  test('фразы не повторяются между уровнями', () {
    final all = <String>[];
    for (final level in levels) {
      for (final p in read('assets/phrases/cefr_$level.json')) {
        all.add(elementsOf(p, 'en').map((e) => e['text']).join(' '));
      }
    }
    expect(all.length, 60);
    expect(all.toSet().length, 60, reason: 'дубликаты фраз');
  });

  test('в каждом уровне ровно 1000 слов с непустыми переводами', () {
    for (final level in levels) {
      final words = read('assets/vocab/words_$level.json');
      expect(words.length, 1000, reason: level);
      for (final w in words) {
        for (final lang in languages) {
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

  test('слова: язык переведён либо во ВСЕХ пунктах уровня, либо ни в одном', () {
    // FlashcardBank проверяет доступность языка по ОДНОМУ пункту (см.
    // hasContentFor) — это дёшево, но полагается на то, что контент
    // никогда не бывает переведён наполовину. Здесь эта гарантия
    // проверяется по-настоящему, по всей тысяче.
    for (final level in levels) {
      final items = read('assets/vocab/words_$level.json');
      final extraLanguages = items
          .expand((item) => item.keys)
          .where((k) => !languages.contains(k))
          .toSet();
      for (final lang in extraLanguages) {
        final withLang = items.where((item) => (item[lang] as String?)?.trim().isNotEmpty ?? false);
        expect(withLang.length, 1000, reason: 'words_$level/$lang: переведена не вся колода');
      }
    }
  });
}
