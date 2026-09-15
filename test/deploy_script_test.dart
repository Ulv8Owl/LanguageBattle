import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Скрипт деплоя перечисляет функции ПОИМЁННО — и это ловушка.
///
/// Новая функция молча остаётся незадеплоенной: приложение зовёт её и
/// получает 404 там, где ждёт ответ. Заметить это можно только на живом
/// телефоне, и выглядит оно как поломка приложения, а не как забытая строка
/// в скрипте. Дешевле поймать здесь.
void main() {
  test('deploy_server.sh деплоит каждую функцию из supabase/functions', () {
    final script = File('tools/deploy_server.sh').readAsStringSync();

    final folders = Directory('supabase/functions')
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split(Platform.pathSeparator).last)
        // _shared — общий код, отдельной функцией не деплоится.
        .where((name) => !name.startsWith('_'))
        .toList()
      ..sort();

    expect(folders, isNotEmpty, reason: 'не нашёл ни одной функции');
    for (final name in folders) {
      expect(
        script,
        contains('functions deploy $name'),
        reason: 'функция «$name» есть в репозитории, но её не деплоят',
      );
    }
  });
}
