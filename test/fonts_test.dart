import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Шрифт без кириллицы не ломает сборку и не выдаёт ошибку — Flutter молча
/// подставляет для русских букв системный, и один и тот же экран начинает
/// выглядеть по-разному на русском и английском. Заметить это можно только
/// глазами, поэтому набор используемых семейств проверяется тестом.
///
/// Baloo 2, Space Mono и Bungee (стояли в теме до перехода на два языка
/// интерфейса) содержат только латиницу. Проверено не по документации, а
/// загрузкой их .ttf с fonts.gstatic.com и разбором таблицы cmap: кода
/// U+0410 «А» в них нет. У Manrope, JetBrains Mono и Russo One — есть.
///
/// Тест читает исходник темы, а не вызывает GoogleFonts: так он не зависит
/// ни от сети, ни от кэша шрифтов, и ловит запрещённое семейство даже в
/// коде, который на текущих экранах ещё не выполняется.
void main() {
  /// Семейства без кириллицы — в виде имён методов google_fonts
  /// (`GoogleFonts.baloo2()` и т.д.).
  const latinOnly = {
    'baloo2': 'Baloo 2',
    'spaceMono': 'Space Mono',
    'bungee': 'Bungee',
  };

  test('в теме нет шрифтов без кириллицы', () {
    final theme = File('lib/core/theme.dart').readAsStringSync();
    for (final entry in latinOnly.entries) {
      expect(
        theme.contains('GoogleFonts.${entry.key}('),
        isFalse,
        reason: 'lib/core/theme.dart использует ${entry.value} — в этом '
            'семействе нет кириллицы, и русский текст будет рисоваться '
            'системным шрифтом, а английский — нет',
      );
    }
  });

  test('во всём приложении шрифты берутся только из AppFonts', () {
    // Прямой вызов GoogleFonts мимо темы — это способ протащить шрифт в
    // обход проверки выше, поэтому вне theme.dart их быть не должно.
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (file.path.endsWith('core/theme.dart')) continue;
      if (file.readAsStringSync().contains('GoogleFonts.')) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'шрифты задаются только в lib/core/theme.dart (AppFonts)');
  });

  test('используемые семейства — из проверенного списка', () {
    final theme = File('lib/core/theme.dart').readAsStringSync();
    // Каждое из этих семейств проверено на наличие кириллицы (см. шапку).
    const cyrillicCapable = ['manrope', 'jetBrainsMono', 'russoOne'];
    final used = RegExp(r'GoogleFonts\.(\w+)')
        .allMatches(theme)
        .map((m) => m.group(1)!)
        // manropeTextTheme — та же Manrope, только сразу темой.
        .map((name) => name.endsWith('TextTheme')
            ? name.substring(0, name.length - 'TextTheme'.length)
            : name)
        .toSet();
    expect(used, isNotEmpty);
    for (final name in used) {
      expect(cyrillicCapable, contains(name),
          reason: 'семейство $name не в списке проверенных на кириллицу — '
              'проверь его субсеты и допиши сюда');
    }
  });
}
