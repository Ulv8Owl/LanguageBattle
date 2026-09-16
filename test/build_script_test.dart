import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Скрипты сборки и деплоя проверяются здесь, потому что больше негде.
///
/// Ошибка в них всплывает не на сборке, а НА ЧУЖОМ КОМПЬЮТЕРЕ посреди
/// деплоя — и выглядит как поломка проекта, а не как забытая строка.
/// Текст скрипта БЕЗ комментариев и без содержимого кавычек.
///
/// Нужен затем, что проверять «скрипт делает X» поиском по файлу нельзя:
/// найдётся и объяснение в комментарии, и подсказка в тексте ошибки. Первая
/// же версия этих проверок на этом и споткнулась — забраковала исправные
/// скрипты за то, что они честно рассказывают, чего НЕ делают.
String commandsOf(String source) {
  final out = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  var inComment = false;
  var previous = '\n';
  for (var i = 0; i < source.length; i++) {
    final c = source[i];
    if (c == '\n') {
      inComment = false;
      out.write('\n');
      previous = '\n';
      continue;
    }
    if (inComment) continue;
    if (inSingle) {
      if (c == "'") inSingle = false;
      continue;
    }
    if (inDouble) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inDouble = false;
      }
      continue;
    }
    if (c == "'") {
      inSingle = true;
      continue;
    }
    if (c == '"') {
      inDouble = true;
      continue;
    }
    // `#` начинает комментарий только в начале слова: иначе под нож попали
    // бы ${#BRANCHES[@]} и $#.
    if (c == '#' && (previous == '\n' || previous == ' ' || previous == '\t')) {
      inComment = true;
      continue;
    }
    out.write(c);
    previous = c;
  }
  return out.toString();
}

void main() {
  String read(String path) => File(path).readAsStringSync();
  String commands(String path) => commandsOf(read(path));

  group('контент едет за кодом', () {
    test('build.sh собирает контент из той же ветки, что и код', () {
      // Фразы, слова и список записей фонотеки лежат не в APK, а в
      // репозитории и тянутся в рантайме (RemoteContent). Без этого флага
      // любая сборка любой ветки читала контент из main: код новый,
      // материал старый. Ломается молча — в main у списка записей другой
      // формат, разбор падает в catch, и фонотека оказывается пустой.
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
  });

  group('android-сборка', () {
    /// Каталоги подключённых пакетов — из того, что разложил pub get.
    Map<String, Directory> resolvedPackages() {
      final config = File('.dart_tool/package_config.json');
      expect(config.existsSync(), isTrue,
          reason: 'нет .dart_tool/package_config.json — сначала flutter pub get');
      final json = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
      final out = <String, Directory>{};
      for (final p in (json['packages'] as List).cast<Map<String, dynamic>>()) {
        final uri = Uri.parse(p['rootUri'] as String);
        final path = uri.scheme == 'file'
            ? uri.toFilePath()
            : Uri.parse(config.absolute.parent.uri.resolveUri(uri).toString()).toFilePath();
        out[p['name'] as String] = Directory(path);
      }
      return out;
    }

    test('Kotlin в плагине не включается «по условию»', () {
      // ═══ САМАЯ ДОРОГАЯ ЛОВУШКА ИЗ ВСТРЕЧЕННЫХ ═══
      //
      // В android/gradle.properties стоит android.builtInKotlin=false —
      // встроенный в AGP Kotlin выключен. А некоторые плагины применяют
      // Kotlin Gradle Plugin УСЛОВНО:
      //
      //     def isAgp9OrAbove = ... >= 9
      //     if (!isAgp9OrAbove) { apply plugin: 'org.jetbrains.kotlin.android' }
      //
      // расчитывая, что на AGP 9 их подхватит встроенный Kotlin. У нас он
      // выключен, а AGP 9 — стоит. Такой плагин собирается ВНЕШНЕ УСПЕШНО:
      // его .kt-файлы просто никто не компилирует. Падает потом ЧУЖОЙ файл
      // — GeneratedPluginRegistrant.java: «cannot find symbol: class
      // FilePickerPlugin». Ни про плагин, ни про pubspec, ни про Kotlin там
      // нет ни слова.
      //
      // Ловим именно УСЛОВНОЕ применение, а не отсутствие применения
      // вообще: плагин может настраивать Kotlin блоком `kotlin { }` и
      // прекрасно собираться (так живёт audioplayers_android). Проверять
      // версию пакета бессмысленно — версия это то, чем ловушка сегодня
      // называется, а условие — то, чем она является.
      if (RegExp(r'android\.builtInKotlin\s*=\s*true')
          .hasMatch(read('android/gradle.properties'))) {
        return;
      }

      final conditional = RegExp(
        r'if\s*\([^)]*\)\s*\{[^}]*apply plugin:\s*[\x27"](kotlin-android|org\.jetbrains\.kotlin\.android)',
        multiLine: true,
      );
      final broken = <String>[];
      resolvedPackages().forEach((name, dir) {
        final gradle = File('${dir.path}/android/build.gradle');
        if (!gradle.existsSync()) return;
        if (conditional.hasMatch(gradle.readAsStringSync())) broken.add(name);
      });

      expect(broken, isEmpty,
          reason: 'эти плагины включают Kotlin по условию, а условие у нас не '
              'выполняется — их классы молча не попадут в сборку: $broken');
    });
  });

  group('ветки', () {
    test('какие ветки есть — спрашиваем GitHub, а не список в скрипте', () {
      // Список имён в скрипте устаревает МОЛЧА, и это уже стоило двух
      // тупиков подряд: он предлагал собрать Omni, которой давно нет, и
      // молчал про Exp3, ради которой скрипт и запускали. Пояснения к
      // веткам в скрипте остаются — устаревшее пояснение никого не
      // останавливает, устаревший список останавливает.
      expect(read('tools/lib.sh'), contains('git ls-remote --heads origin'));
      final release = read('tools/release.sh');
      expect(release, contains('remote_branches'));
      expect(
        release.contains('KNOWN_BRANCHES'),
        isFalse,
        reason: 'список веток снова зашит в скрипт — он опять устареет',
      );
    });

    test('подсказка про регистр берётся из живого списка', () {
      // git различает Exp3 и exp3, и подсказка «а вот такая есть» обязана
      // строиться по тому, что на GitHub, иначе она тоже устареет.
      final release = read('tools/release.sh');
      final at = release.indexOf('SUGGEST=');
      expect(at, greaterThan(0));
      expect(release.substring(at, at + 400), contains(r'"${BRANCHES[@]}"'));
    });
  });

  group('синхронизация', () {
    test('разошедшиеся ветки — не тупик', () {
      // Здесь стоял голый `git merge --ff-only`, и на разошедшихся ветках
      // он оставлял человека там же, откуда тот пришёл: «перемотка
      // невозможна, сделай git reset --hard». Скрипт, обещающий сделать всё
      // сам, отправлял чинить руками — а deploy_server.sh советовал
      // запустить как раз его. Совет ходил по кругу.
      final lib = read('tools/lib.sh');
      expect(lib, contains('sync_to_origin()'));
      expect(lib, contains('git rev-list --count "origin/\$branch..HEAD"'));
      expect(lib, contains('git rev-list --count "HEAD..origin/\$branch"'));
    });

    test('свои коммиты сначала сохраняются, и только потом пропадают', () {
      // Распоряжаться чужой работой молча нельзя ни при каких условиях.
      final lib = commands('tools/lib.sh');
      final reset = lib.indexOf('git reset --hard');
      expect(reset, greaterThan(0), reason: 'сброса нет вовсе — проверять нечего');
      final before = lib.substring(0, reset);
      expect(
        before.lastIndexOf('git branch '),
        greaterThan(before.lastIndexOf('read -r choice')),
        reason: 'ветка-копия обязана создаваться после ответа и до сброса',
      );
      // И без терминала не решаем за человека вовсе.
      expect(read('tools/lib.sh'), contains('if [ ! -t 0 ]; then'));
    });

    test('после синхронизации git pull работает без аргументов', () {
      // Иначе git отвечает «у текущей ветки нет информации об
      // отслеживании», и человек застревает на ровном месте.
      expect(read('tools/lib.sh'), contains('git branch --set-upstream-to='));
    });

    test('историю трогает ровно одно место', () {
      // Два места, переключающие ветки, однажды разойдутся по правилам —
      // и одно из них снова оставит дерево не тем, что деплоят.
      expect(read('tools/release.sh'), contains('sync_to_origin "\$BRANCH"'));
      for (final step in ['tools/release.sh', 'tools/deploy_server.sh', 'tools/build.sh']) {
        final script = commands(step);
        for (final dangerous in ['git merge', 'git reset', 'git checkout']) {
          expect(script.contains(dangerous), isFalse, reason: '$step: $dangerous');
        }
      }
      // А шаги поодиночке историю не трогают вообще: они только проверяют.
      for (final step in ['tools/deploy_server.sh', 'tools/build.sh']) {
        expect(read(step), contains('require_synced'));
      }
    });

    test('release.sh передаёт ветку в build.sh, а не собирает сам', () {
      // Два места, вызывающие flutter build, разошлись бы по флагам — и
      // один из путей снова начал бы собирать не тот контент.
      final release = read('tools/release.sh');
      expect(release, contains(r'./tools/build.sh "$BRANCH"'));
      expect(release.contains('flutter build apk'), isFalse);
    });
  });

  test('скрипты разбираются bash-ем', () {
    // Опечатка в bash не видна ничем, кроме запуска, а запускают эти
    // скрипты в середине деплоя на чужом компьютере.
    for (final script in Directory('tools')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sh'))) {
      final result = Process.runSync('bash', ['-n', script.path]);
      expect(result.exitCode, 0, reason: '${script.path}: ${result.stderr}');
    }
  });
}
