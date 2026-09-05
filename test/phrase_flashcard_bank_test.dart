import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/data/flashcard_bank.dart';
import 'package:language_battle/data/phrase_bank.dart';

/// Фраза раунда приходит разбитой на элементы (датасет assets/cefr), и на
/// этом разбиении держатся две вещи: подсказки («переверни элемент») и
/// поэлементная оценка на сервере. Проверяем именно склейку и смещения —
/// то, чем клиент и сервер обязаны совпасть.
///
/// Готовых пояснений в банке больше нет: разбор ошибок пишет модель по
/// факту ответа и присылает его в grammar_errors.message.
void main() {
  /// Кусок реального банка: первая фраза A1 в трёх языках.
  PhraseEntry sample() => PhraseEntry.fromJson(const {
        'elements': {
          'en': [
            {'lead': '', 'text': 'I get up'},
            {'lead': ' ', 'text': 'at seven'},
            {'lead': '. ', 'text': 'Then I make'},
          ],
          'ru': [
            {'lead': '', 'text': 'Я встаю'},
            {'lead': ' ', 'text': 'в семь'},
            {'lead': '. ', 'text': 'Потом я делаю'},
          ],
        },
        'tail': {'en': '.', 'ru': '.'},
      });

  test('фраза для показа собирается без разделителей', () {
    final entry = sample();
    expect(entry.forLanguage('en'), 'I get up at seven. Then I make.');
    expect(entry.forLanguage('ru'), 'Я встаю в семь. Потом я делаю.');
    // Языка нет в банке — null, а не выдуманная подстановка на английский.
    expect(entry.forLanguage('zh'), isNull);
  });

  test('эталон для сервера собирается С разделителями', () {
    // Игрок «|» не видит никогда, сервер — обязан: по ним он режет фразу
    // на элементы и считает балл.
    expect(sample().markedForLanguage('en'), 'I get up| at seven|. Then I make|.');
  });

  test('смещения элементов совпадают с чистой фразой', () {
    // Тот же расчёт делает сервер (parseElements в elementScoring.ts), и
    // именно смещениями он присылает непроизнесённые элементы. Разойдясь,
    // клиент подсветил бы не тот кусок.
    final entry = sample();
    final clean = entry.forLanguage('en')!;
    final offsets = entry.elementOffsets('en');
    final elements = entry.elementsFor('en');
    expect(offsets.length, elements.length);
    for (var i = 0; i < elements.length; i++) {
      expect(
        clean.substring(offsets[i], offsets[i] + elements[i].text.length),
        elements[i].text,
        reason: 'элемент $i',
      );
    }
  });

  test('число элементов одинаково во всех языках — на этом стоят подсказки', () {
    final entry = sample();
    expect(entry.elementCount('en'), entry.elementCount('ru'));
  });

  test('FlashcardEntry.forLanguage — прежнее поведение', () {
    final entry = FlashcardEntry.fromJson(const {'en': 'dolphin', 'ru': 'дельфин', 'es': 'delfín'});
    expect(entry.forLanguage('es'), 'delfín');
    expect(entry.forLanguage('de'), isNull);
  });

  test('PhraseBank.textFor не бросает на неизвестном языке — пустая строка', () {
    // textFor дёргают экраны напрямую, и оно обязано остаться безопасным
    // даже без предварительной проверки hasContentFor: пустая строка в
    // тексте раунда — заметный, но не падающий сбой.
    expect(PhraseBank.textFor(999999, 'xx'), '');
    expect(PhraseBank.markedTextFor(999999, 'xx'), '');
    expect(PhraseBank.elementsFor(999999, 'xx'), isEmpty);
  });
}
