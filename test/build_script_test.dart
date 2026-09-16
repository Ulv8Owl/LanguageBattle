import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Сборка обязана брать код и контент из ОДНОЙ ветки.
///
/// Фразы, слова и список записей фонотеки лежат не в APK, а в репозитории и
/// тянутся в рантайме (RemoteContent). Ветку для них задаёт
/// `--dart-define=CONTENT_BRANCH`, и этого флага в build.sh не было: любая
/// сборка любой ветки читала контент из main. Ломается молча — в main у
/// списка записей другой формат, разбор падает в catch, и фонотека просто
/// оказывается пустой. Понять по экрану причину нечем.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('build.sh собирает контент из той же ветки, что и код', () {
    final script = read('tools/build.sh');
    expect(script, contains(r'--dart-define=CONTENT_BRANCH="$BRANCH"'));
    // Ветка берётся из аргумента, а не зашита в скрипт: иначе флаг
    // сообщал бы одно и то же про любую сборку.
    expect(script, contains(r'BRANCH="${1:'));
  });

  test('умолчание ветки контента — main', () {
    // Сборка без скрипта (flutter build руками, IDE) обязана оставаться
    // предсказуемой: main — проверенный контент.
    expect(
      read('lib/data/remote_content.dart'),
      contains("String.fromEnvironment('CONTENT_BRANCH', defaultValue: 'main')"),
    );
  });

  test('список веток в release.sh не врёт про проект', () {
    // Устаревший список хуже отсутствующего: он предлагает собрать ветку,
    // которой нет, и молчит о той, ради которой скрипт и запускают. Ровно
    // это и было: в списке стояли Omni (её на GitHub нет) и LLM (слита в
    // features слово в слово и удалена), а Exp3 не стояло.
    final release = read('tools/release.sh');
    final list = RegExp(r'KNOWN_BRANCHES=\(([^)]*)\)').firstMatch(release);
    expect(list, isNotNull);
    final branches = list!
        .group(1)!
        .split(RegExp(r'\s+'))
        .where((b) => b.isNotEmpty)
        .toList();
    expect(branches, contains('features'));
    expect(branches, contains('Exp3'));
    expect(branches, isNot(contains('Omni')));
    for (final branch in branches) {
      expect(release, contains('$branch)'), reason: 'нет пояснения для $branch');
    }
  });

  test('release.sh передаёт ветку в build.sh, а не собирает сам', () {
    // Два места, вызывающие flutter build, разошлись бы по флагам — и один
    // из путей снова начал бы собирать не тот контент.
    final release = read('tools/release.sh');
    expect(release, contains(r'./tools/build.sh "$BRANCH"'));
    expect(release.contains('flutter build apk'), isFalse);
  });
}
