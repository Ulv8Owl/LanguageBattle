import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/core/app_strings.dart';
import 'package:language_battle/data/streaks.dart';

/// Порядок, названия и значки режимов Арены.
///
/// ЧТО ЭТО СТОРОЖИТ. Имя режима стоит не только в списке Арены: тот же
/// текст — заголовок экрана самого режима, строка в магазине, подпись в
/// «Любимом режиме» Профиля. Пока имена лежали строками по экранам,
/// переименование означало найти их все, и одно место всегда оставалось
/// со старым названием — а выглядит это как два разных режима.
void main() {
  String read(String path) => File(path).readAsStringSync();

  /// Dart-файл БЕЗ КОММЕНТАРИЕВ. В пояснениях старые имена упомянуты
  /// нарочно — чтобы не вернули по кругу, — и проверка, считающая иначе,
  /// ловит собственные объяснения (правило CLAUDE.md: объяснение в
  /// комментарии — не код).
  String code(String path) => read(path)
      .split('\n')
      .where((line) {
        final t = line.trimLeft();
        return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
      })
      .join('\n');

  /// Все файлы `lib/`, кроме самого словаря строк: имена режимов живут
  /// только там.
  List<String> libFiles({String? except}) {
    return Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => p.endsWith('.dart') && p != except)
        .toList();
  }

  group('порядок и названия режимов', () {
    test('список Арены идёт сверху вниз в заданном порядке', () {
      final arena = code('lib/features/arena/arena_screen.dart');
      // Пары «значок — название»: значок каждого режима стоит прямо над
      // его названием, поэтому проверка одной цепочкой ловит и
      // перепутанный порядок, и значок, уехавший к чужому режиму.
      //
      // Имя строки режима пишется коротким `s.` — плашка режима зовёт тот
      // же словарь полным `AppLocale.strings.`, и без префикса `title: s.`
      // проверка нашла бы сначала её.
      const chain = [
        'ModeGlyphKind.cards',
        'title: s.modeFlashcards,',
        'Icons.headphones',
        'title: s.modeListening,',
        'ModeGlyphKind.mic)',
        'title: s.modeVoice,',
        'ModeGlyphKind.micDuo',
        'title: s.modeVoiceDuel,',
        'ModeGlyphKind.message',
        'title: s.modeTalk,',
      ];
      var previous = -1;
      for (final marker in chain) {
        final at = arena.indexOf(marker);
        expect(at, greaterThan(previous), reason: '$marker не на своём месте');
        previous = at;
      }
    });

    test('имена режимов взяты из AppStrings, а не написаны строкой', () {
      // Старых имён в коде не должно остаться нигде: переименование, из
      // которого один экран не узнал, выглядит как два разных режима.
      const gone = ['Тренировка', 'Одиночная Игра', 'Состязание', 'Дуэль'];
      for (final path in libFiles()) {
        final body = code(path);
        for (final name in gone) {
          expect(body.contains("'$name'"), isFalse,
              reason: '$path держит старое имя «$name» строкой');
        }
      }
    });

    test('новые имена лежат в одном месте — в AppStrings', () {
      const names = ['Флэш-Карточки', 'Голос Vs Голос'];
      for (final path in libFiles(except: 'lib/core/app_strings.dart')) {
        final body = code(path);
        for (final name in names) {
          expect(body.contains("'$name'"), isFalse,
              reason: '$path завёл вторую копию имени «$name»');
        }
      }
    });
  });

  group('словарь имён', () {
    test('русские названия — ровно те, что заказаны', () {
      expect(AppStrings.ru.modeFlashcards, 'Флэш-Карточки');
      expect(AppStrings.ru.modeListening, 'Аудирование');
      expect(AppStrings.ru.modeVoice, 'Голос');
      expect(AppStrings.ru.modeVoiceDuel, 'Голос Vs Голос');
      expect(AppStrings.ru.modeTalk, 'Общение');
    });

    test('английский интерфейс получает свои названия, а не русские', () {
      expect(AppStrings.en.modeFlashcards, 'Flashcards');
      expect(AppStrings.en.modeListening, 'Listening');
      expect(AppStrings.en.modeVoice, 'Voice');
      expect(AppStrings.en.modeVoiceDuel, 'Voice Vs Voice');
      expect(AppStrings.en.modeTalk, 'Talk');
      // Ни одно английское имя не совпадает с русским: совпадение здесь
      // означало бы забытый перевод, а не удачное слово.
      final ru = [
        AppStrings.ru.modeFlashcards,
        AppStrings.ru.modeListening,
        AppStrings.ru.modeVoice,
        AppStrings.ru.modeVoiceDuel,
        AppStrings.ru.modeTalk,
      ];
      final en = [
        AppStrings.en.modeFlashcards,
        AppStrings.en.modeListening,
        AppStrings.en.modeVoice,
        AppStrings.en.modeVoiceDuel,
        AppStrings.en.modeTalk,
      ];
      for (var i = 0; i < ru.length; i++) {
        expect(en[i], isNot(ru[i]));
      }
    });

    test('«Любимый режим» в Профиле зовёт режимы теми же именами', () {
      // Коды в practice_days НЕ переименовываются вместе с именами:
      // сменишь код — и вчерашние дни перестанут совпадать с сегодняшними.
      expect(PracticeMode.training.code, 'training');
      expect(PracticeMode.solo.code, 'solo');
      expect(PracticeMode.listening.code, 'listening');
      expect(PracticeMode.battle.code, 'battle');

      expect(PracticeMode.titleOf('training'), AppStrings.ru.modeFlashcards);
      expect(PracticeMode.titleOf('solo'), AppStrings.ru.modeVoice);
      expect(PracticeMode.titleOf('listening'), AppStrings.ru.modeListening);
      expect(PracticeMode.titleOf('battle'), AppStrings.ru.modeBattle);
    });
  });

  group('значки режимов', () {
    test('нарисованы свои: колода веером, микрофон, два микрофона, окно', () {
      final glyphs = code('lib/widgets/mode_glyphs.dart');
      for (final kind in ['cards', 'mic', 'micDuo', 'message']) {
        expect(glyphs, contains('ModeGlyphKind.$kind'),
            reason: 'нет ветки рисования для $kind');
      }
      // Веер — это пять карт, сведённых в одну точку. Один угол вместо
      // списка означал бы стопку, а её от веера не отличить.
      expect(glyphs, contains('const angles = [-0.60, -0.30, 0.0, 0.30, 0.60];'));
      // Два микрофона — это ДВА вызова одного и того же рисования.
      expect(glyphs, contains('one(6.9, -0.20);'));
      expect(glyphs, contains('one(17.1, 0.20);'));
    });

    test('плашка значка принимает либо icon, либо glyph, но не оба', () {
      // Оба сразу — это две картинки друг на друге. Держит это assert, а
      // не комментарий: комментарий ничего не проверяет.
      final widgets = code('lib/widgets/chrolingo_widgets.dart');
      expect(widgets, contains('assert((icon == null) != (glyph == null)'));
    });
  });
}
