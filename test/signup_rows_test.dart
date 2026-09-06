import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/data/signup_rows.dart';

/// Регистрация нового игрока падала на первом же экране: в групповой вставке
/// одна строка не называла is_active, PostgREST подставил туда NULL вместо
/// значения по умолчанию, и сработало ограничение not-null.
void main() {
  final rows = signupLanguageRows(
    userId: 'u-1',
    nativeLanguage: 'ru',
    targetLanguage: 'en',
  );

  test('все строки групповой вставки называют одни и те же столбцы', () {
    final expected = rows.first.keys.toSet();
    for (final row in rows) {
      expect(row.keys.toSet(), expected,
          reason: 'разный набор ключей превращает умолчание схемы в NULL');
    }
  });

  test('ни одно значение не пустое, кроме осмысленного null', () {
    // native_for у родной строки — единственное законное исключение: она
    // и есть родной язык, ссылаться ей не на что. Ключ при этом обязан
    // присутствовать, иначе наборы столбцов разойдутся (тест выше).
    for (final row in rows) {
      for (final entry in row.entries) {
        if (row['role'] == 'native' && entry.key == 'native_for') continue;
        expect(entry.value, isNotNull, reason: 'столбец ${entry.key}');
      }
    }
  });

  test('изучаемая пара помнит, с какого языка её учат', () {
    // Без native_for пара следовала за users.native_language: сменив
    // главный родной с русского на английский, игрок получал пару en-en —
    // язык сам себе родной.
    final learning = rows.firstWhere((r) => r['role'] == 'learning');
    expect(learning['native_for'], 'ru');
  });

  test('активна изучаемая пара, а не родной язык', () {
    final native = rows.firstWhere((r) => r['role'] == 'native');
    final learning = rows.firstWhere((r) => r['role'] == 'learning');
    expect(native['is_active'], false);
    expect(learning['is_active'], true);
    expect(native['language_code'], 'ru');
    expect(learning['language_code'], 'en');
  });
}
