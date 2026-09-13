import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Сборка обязана брать код и контент из ОДНОЙ ветки.
///
/// Фразы, слова и список треков лежат не в APK, а в репозитории и тянутся в
/// рантайме (RemoteContent). Ветку для них задаёт --dart-define=
/// CONTENT_BRANCH, и этого флага в build.sh не было: любая сборка любой
/// ветки читала контент из main. Спасал только откат на бандл — то есть
/// ровно до первого файла, который в main всё-таки есть.
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
    // которой нет, и молчит о той, ради которой скрипт и запускают.
    final release = read('tools/release.sh');
    for (final branch in ['main', 'features', 'Exp2']) {
      expect(release, contains(branch), reason: branch);
    }
    final list = RegExp(r'KNOWN_BRANCHES=\(([^)]*)\)').firstMatch(release);
    expect(list, isNotNull);
    for (final branch in list!.group(1)!.split(RegExp(r'\s+'))) {
      if (branch.isEmpty) continue;
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
