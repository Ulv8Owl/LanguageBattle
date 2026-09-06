import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Игрок с несколькими парами упирался в выбор уровня и не мог пройти
/// дальше: и «Начать игру», и сама проверка отвечали
/// placement_already_done, обойти было нечем.
///
/// Складывалось из двух половин, каждая безобидная поодиночке. Маршрут на
/// старте брал ЛЮБУЮ строку learning и по её placement_done решал, вести ли
/// на экран уровня. Экраны при этом работают с АКТИВНОЙ парой, у которой
/// уровень давно определён. Маршрут вёл на экран из-за одной пары, а экран
/// действовал на другую.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('маршрут на старте спрашивает активную пару', () {
    final routing = read('lib/core/start_destination.dart');
    // Решение о шаге регистрации принимается по той же паре, с которой
    // работают экраны. Иначе это жребий: у игрока с двумя парами вторая
    // приходит с placement_done = false, и выпасть могла она.
    final decision = routing.substring(
      routing.indexOf('final active = await supabase'),
      routing.indexOf('return done ? StartDestination.arena'),
    );
    expect(decision, contains("eq('is_active', true)"));
    expect(decision, contains("eq('role', 'learning')"));
  });

  test('без активной пары не отправляем заново в онбординг', () {
    // Строки есть, активной нет — это поломка, но заводить пару заново
    // поверх существующих хуже, чем пустить в Арену, где её выбирают
    // руками.
    final routing = read('lib/core/start_destination.dart');
    expect(routing, contains('any.isEmpty ? StartDestination.onboarding : StartDestination.arena'));
  });

  test('проверка уровня адресует пару определённо, а не наугад', () {
    final sql = read('supabase/migrations/0036_placement_targets_active_pair.sql');
    // После 0034 у игрока могут быть две пары с одним изучаемым языком
    // (ru-es и en-es). `limit 1` без порядка выбирал из них жребием.
    // Каждый limit 1 в КОДЕ функций снабжён порядком. Считаем по строкам
    // кода, а не по всему файлу: слова «limit 1» есть и в шапочном
    // комментарии, где описано, как было раньше.
    final code = sql.split('\n').where((l) => !l.trimLeft().startsWith('--')).toList();
    final limits = code.where((l) => l.contains('limit 1')).length;
    final orders =
        code.where((l) => l.contains('order by is_active desc, native_for')).length;
    expect(orders, 3, reason: 'три выборки пары — все три должны быть упорядочены');
    expect(limits, orders, reason: 'limit 1 без порядка — это жребий с видом выбора');
  });

  test('уровень записывается ровно в одну строку', () {
    final sql = read('supabase/migrations/0036_placement_targets_active_pair.sql');
    // Прежний update шёл по фильтру language_code и мог задеть обе пары с
    // этим изучаемым языком разом. Теперь сначала выбираем id.
    expect(sql, contains('update user_languages'));
    expect(sql, contains('where id = v_id;'));
  });
}
