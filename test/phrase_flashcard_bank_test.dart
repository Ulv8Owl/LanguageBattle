import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/data/flashcard_bank.dart';
import 'package:language_battle/data/phrase_bank.dart';

/// PhraseEntry/FlashcardEntry раньше были тремя жёстко зашитыми полями
/// (ru/en/es) — переход на произвольную карту ключей не должен был
/// поменять поведение для уже существующих языков и обязан честно
/// сигнализировать отсутствие нового.
void main() {
  test('PhraseEntry.forLanguage — известный язык возвращает текст, неизвестный — null', () {
    final entry = PhraseEntry.fromJson(const {'en': 'Hello', 'ru': 'Привет', 'es': 'Hola'});
    expect(entry.forLanguage('en'), 'Hello');
    expect(entry.forLanguage('ru'), 'Привет');
    // Ключа для этого языка ещё нет в контенте — null, а не выдуманная
    // подстановка на английский, как было в старой switch-реализации.
    expect(entry.forLanguage('zh'), isNull);
  });

  test('FlashcardEntry.forLanguage — то же самое поведение, что у PhraseEntry', () {
    final entry = FlashcardEntry.fromJson(const {'en': 'dolphin', 'ru': 'дельфин', 'es': 'delfín'});
    expect(entry.forLanguage('es'), 'delfín');
    expect(entry.forLanguage('de'), isNull);
  });

  test('PhraseBank.textFor не бросает на неизвестном языке — пустая строка', () {
    // textFor — единственное место, которое звонки экранов дёргают
    // напрямую (battle_screen/training_screen), и оно обязано остаться
    // безопасным даже без предварительной проверки hasContentFor: пустая
    // строка в тексте раунда — заметный, но не падающий сбой.
    expect(PhraseBank.textFor(999999, 'xx'), '');
  });
}
