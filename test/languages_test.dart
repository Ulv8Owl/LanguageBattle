import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/all_languages.dart';
import 'package:language_battle/core/languages.dart';

void main() {
  test('подпись к заданию — про перевод, а не про повтор', () {
    expect(translateToLabel('en'), 'Переведи на английский:');
    expect(translateToLabel('es'), 'Переведи на испанский:');
    expect(translateToLabel('ru'), 'Переведи на русский:');
    expect(translateToLabel('de'), 'Переведи на немецкий:');
  });

  test('язык вне реестра не роняет подписи', () {
    expect(translateToLabel('xx'), 'Переведи на изучаемый язык:');
    expect(recognisingSpeechLabel('xx'), 'Распознавание речи');
  });

  test('подпись распознавания читается на любом языке', () {
    expect(recognisingSpeechLabel('en'), 'Распознавание английской речи');
    expect(recognisingSpeechLabel('ru'), 'Распознавание русской речи');
    // У несклоняемых названий прилагательного нет — форма другая, но
    // читается так же правильно. Ради этих трёх случаев форма и хранится
    // готовой, а не собирается по шаблону.
    expect(recognisingSpeechLabel('hi'), 'Распознавание речи на хинди');
    expect(recognisingSpeechLabel('ur'), 'Распознавание речи на урду');
    expect(recognisingSpeechLabel('he'), 'Распознавание речи на иврите');
  });

  test('в реестре 32 языка, каждый заполнен целиком', () {
    expect(allLanguages.length, 32);
    for (final entry in allLanguages.entries) {
      expect(entry.value.endonym.trim(), isNotEmpty, reason: entry.key);
      expect(entry.value.accusative.trim(), isNotEmpty, reason: entry.key);
      expect(entry.value.speech.trim(), isNotEmpty, reason: entry.key);
      // Подпись подставляется как «Распознавание <speech>», поэтому форма
      // обязана быть в родительном падеже: либо «<какой-то>ой речи», либо
      // «речи на <языке>» у несклоняемых. Иначе получится «Распознавание
      // английская речь».
      expect(entry.value.speech, contains('речи'), reason: entry.key);
      expect(entry.value.flag.trim(), isNotEmpty, reason: entry.key);
      expect(entry.value.scripts, isNotEmpty, reason: entry.key);
    }
  });

  test('все двенадцать самых изучаемых языков на месте', () {
    // Ради этого список и подбирался: игрок не должен обнаружить, что
    // его изучаемого языка в игре нет вовсе.
    for (final code in ['en', 'es', 'fr', 'de', 'ja', 'ko', 'zh', 'it', 'pt', 'ru', 'ar', 'hi']) {
      expect(allLanguages.containsKey(code), isTrue, reason: 'нет $code');
    }
  });

  test('таблица языков на клиенте и на сервере — один и тот же набор кодов', () {
    // Две таблицы (Dart для интерфейса, TypeScript для распознавания речи)
    // физически не могут быть одним файлом: разные рантаймы. Значит, они
    // обязаны сверяться тестом, иначе разъедутся молча — и язык, который
    // игрок видит в списке, окажется неизвестен ASR (или наоборот).
    final ts = File('supabase/functions/_shared/asr/languages.ts').readAsStringSync();
    final table = ts.substring(
      ts.indexOf('const LANGUAGES'),
      ts.indexOf('};', ts.indexOf('const LANGUAGES')),
    );
    final serverCodes = RegExp(r'^\s{2}([a-z]{2,3}): \{ bcp47:', multiLine: true)
        .allMatches(table)
        .map((m) => m.group(1)!)
        .toSet();

    expect(serverCodes, allLanguages.keys.toSet());
  });
}
