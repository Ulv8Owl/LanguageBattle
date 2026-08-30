import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/languages.dart';

void main() {
  test('подпись к заданию — про перевод, а не про повтор', () {
    expect(translateToLabel('en'), 'Переведи на английский:');
    expect(translateToLabel('es'), 'Переведи на испанский:');
    expect(translateToLabel('ru'), 'Переведи на русский:');
  });

  test('незнакомый язык не роняет подпись', () {
    expect(translateToLabel('de'), 'Переведи на изучаемый язык:');
  });
}
