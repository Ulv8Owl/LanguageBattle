import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/features/battle/battle_models.dart';

MatchData match(String mode) => MatchData(
      id: 'm1',
      playerAId: 'a',
      playerBId: 'b',
      gameMode: mode,
      languagePair: 'ru-en',
      status: 'in_progress',
      winnerId: null,
      forfeitedBy: null,
      createdAt: DateTime.utc(2026),
    );

void main() {
  test('в Дуэли сначала перевод, потом родная речь', () {
    // Обратный порядок обессмысливал раунд: игрок сперва читал вслух
    // родной текст, а потом «переводил» уже произнесённое им самим.
    expect(match('native_duel').requiredSlots, ['target', 'native']);
  });

  test('в Состязании слот один — перевод', () {
    expect(match('sparring').requiredSlots, ['target']);
  });

  test('язык слота в Дуэли зеркальный для двух игроков', () {
    final m = match('native_duel');
    expect(m.languageForSlot('a', 'target'), 'en');
    expect(m.languageForSlot('a', 'native'), 'ru');
    expect(m.languageForSlot('b', 'target'), 'ru');
    expect(m.languageForSlot('b', 'native'), 'en');
  });
}
