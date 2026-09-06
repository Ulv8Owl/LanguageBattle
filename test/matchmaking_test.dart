import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Состязание не находило соперника, даже когда он стоял в очереди рядом с
/// той же языковой парой. Окно рейтинга росло 100 → 250 → 600 и на этом
/// останавливалось, а разница между прошедшим проверку уровня (1500) и
/// новичком (600) — 900. Поиск не мог завершиться успехом ни при каком
/// ожидании: это тупик, а не строгий подбор.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String screen() => read('lib/features/matchmaking/matchmaking_screen.dart');
  String migration() => read('supabase/migrations/0041_mm_reason.sql');

  test('окно рейтинга в конце ничем не ограничено', () {
    final s = screen();
    // Первые шаги остаются узкими: равный соперник лучше, если он есть.
    expect(s, contains('if (elapsedSeconds < 10) return 100;'));
    expect(s, contains('if (elapsedSeconds < 20) return 250;'));
    // А последний обязан покрывать кого угодно, иначе поиск бесконечен.
    expect(s, contains('return 1000000;'));
    expect(s.contains('return 600;'), isFalse);
  });

  test('условие по языкам живёт в одном месте', () {
    // Оно нужно и поиску, и подсчёту «сколько подошло бы по языку». Две
    // копии разъехались бы, и объяснение перестало бы совпадать с
    // поведением поиска.
    final sql = migration();
    expect(sql, contains('function public.mm_languages_fit'));
    // Оба места зовут предикат, а не повторяют условие: сравнения языков
    // вне самой функции быть не должно.
    expect('mm_languages_fit(v_me, t)'.allMatches(sql).length, 2);
    final outsideHelper = sql.substring(sql.indexOf('function public.mm_search'));
    expect(outsideHelper.contains('t.target_language = v_me'), isFalse);
    expect(outsideHelper.contains('countrymen_only'), isFalse);
  });

  test('поиск объясняет, почему никого не нашёл', () {
    final sql = migration();
    // «В очереди никого» и «соперник есть, но рейтинг далеко» — разные
    // вещи: второе чинится ожиданием, первое нет.
    expect(sql, contains("'by_language'"));
    expect(sql, contains("'nearest_gap'"));
    expect(screen(), contains('String _noteFor(Map<String, dynamic> map)'));
    expect(screen(), contains('Пока никто не ищет соперника на этом языке.'));
    expect(screen(), contains('рейтинг далеко'));
  });

  test('сбой поиска больше не прячется', () {
    // Ошибка уходила в debugPrint, и падающий на каждом тике поиск
    // выглядел на экране как обычное ожидание.
    final s = screen();
    expect(s, contains('Поиск отвечает ошибкой:'));
    expect(s.contains("debugPrint('mm_search failed"), isFalse);
  });

  test('дуэли объяснение своё', () {
    // Там нужен не «кто-то на этом языке», а носитель изучаемого,
    // который учит твой родной, — и сказать это надо иначе.
    expect(screen(), contains('нужен носитель твоего'));
  });
}
