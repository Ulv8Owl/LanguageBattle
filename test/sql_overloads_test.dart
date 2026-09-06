import 'dart:io';

/// Перегрузка функции — самая дорогая опечатка в этих миграциях.
///
/// Postgres различает функции по СИГНАТУРЕ, а не по имени. `create or
/// replace function f(a, b)` НЕ заменяет прежнюю `f(a)` — он заводит рядом
/// вторую, и с этого момента вызов с одним аргументом становится
/// неоднозначным. PostgREST отвечает на такой вызов PGRST203 и не зовёт
/// ничего: функция перестаёт работать целиком, хотя обе её версии в базе
/// исправны.
///
/// Ловушка описана в 0025 для add_language_pair и обойдена явным drop —
/// и всё равно повторена в 0034 для set_active_language_pair. Значение по
/// умолчанию у нового параметра создаёт иллюзию совместимости: старый
/// вызов поддерживается ровно до тех пор, пока рядом нет второй функции,
/// которая тоже готова его принять. Глазами это не ловится, поэтому здесь.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ни одна функция не объявлена с разным числом параметров без drop', () {
    final files = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sql'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    // имя функции -> { число параметров -> файл, где так объявлена }
    final arities = <String, Map<int, String>>{};
    final dropped = <String>{};

    final declare = RegExp(
      r'create\s+or\s+replace\s+function\s+(?:public\.)?(\w+)\s*\(',
      caseSensitive: false,
    );
    final drop = RegExp(
      r'drop\s+function\s+(?:if\s+exists\s+)?(?:public\.)?(\w+)\s*\(',
      caseSensitive: false,
    );

    for (final file in files) {
      final sql = file.readAsStringSync();
      final name = file.uri.pathSegments.last;

      for (final m in drop.allMatches(sql)) {
        dropped.add(m.group(1)!);
      }

      for (final m in declare.allMatches(sql)) {
        final fn = m.group(1)!;
        final params = _paramCount(sql, m.end - 1);
        arities.putIfAbsent(fn, () => {}).putIfAbsent(params, () => name);
      }
    }

    final offenders = <String>[];
    arities.forEach((fn, byArity) {
      if (byArity.length < 2) return;
      if (dropped.contains(fn)) return;
      final where = byArity.entries
          .map((e) => '${e.value}: ${e.key} параметр(ов)')
          .join(', ');
      offenders.add('$fn — $where');
    });

    expect(
      offenders,
      isEmpty,
      reason: 'функция объявлена с разным числом параметров и не снята '
          'явным drop — в базе останутся ОБЕ версии, и вызов станет '
          'неоднозначным (PGRST203):\n  ${offenders.join('\n  ')}',
    );
  });
}

/// Сколько параметров в сигнатуре, начиная с открывающей скобки [open].
///
/// Считаем запятые на нулевой глубине вложенности: значения по умолчанию
/// (`default null`) запятых не содержат, а вложенные скобки — например
/// `numeric(10,2)` — считаться не должны.
int _paramCount(String sql, int open) {
  var depth = 0;
  var commas = 0;
  var body = '';
  for (var i = open; i < sql.length; i++) {
    final c = sql[i];
    if (c == '(') {
      depth++;
      if (depth == 1) continue;
    } else if (c == ')') {
      depth--;
      if (depth == 0) break;
    } else if (c == ',' && depth == 1) {
      commas++;
    }
    if (depth >= 1) body += c;
  }
  return body.trim().isEmpty ? 0 : commas + 1;
}
