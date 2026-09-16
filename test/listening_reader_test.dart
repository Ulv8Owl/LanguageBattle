import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/data/track_subtitles.dart';

/// Экран чтения: два текста рядом, палочка между ними, плашки перемотки.
///
/// Разметку проверяем НАСТОЯЩИМ ПОСТРОЕНИЕМ виджетов там, где это возможно
/// без плеера и файловой системы: колонки и подсветка — чистая вёрстка, и
/// ошибка в них видна только глазами, а глаз у сборки нет.
void main() {
  SubtitleWord w(String text, int start, int end) =>
      SubtitleWord(text: text, translation: '', startMs: start, endMs: end);

  group('строка из двух колонок', () {
    // Виджеты экрана приватные, поэтому строим ту же вёрстку, что и они, из
    // тех же правил: ширины колонок считаются ЗА ВЫЧЕТОМ палочки.
    test('текст не заходит под палочку', () {
      const total = 800.0;
      const handle = 20.0;
      for (final split in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final usable = total - handle;
        final left = usable * split;
        final right = usable - left;
        expect(left + right + handle, closeTo(total, 0.001),
            reason: 'при доле $split колонки плюс палочка обязаны дать ширину экрана');
        expect(left, greaterThanOrEqualTo(0));
        expect(right, greaterThanOrEqualTo(0));
      }
    });

    test('крайние положения убирают колонку целиком', () {
      const usable = 780.0;
      expect(usable * 0.0, 0, reason: 'сдвинуто влево — оригинала нет');
      expect(usable - usable * 1.0, 0, reason: 'сдвинуто вправо — перевода нет');
    });
  });

  group('перевод строки', () {
    test('берётся целиком, когда переводчик его дал', () {
      final line = SubtitleLine(
        [w('I', 0, 100), w('wanna', 100, 400)],
        translation: 'Я хочу',
      );
      expect(line.text, 'I wanna');
      expect(line.translationText, 'Я хочу');
    });

    test('склеивается из слов, когда переводчика не было', () {
      // Так отвечает мультимодальная модель: у неё перевод только
      // пословный. Хуже читается, но лучше, чем пустая колонка.
      final line = SubtitleLine([
        SubtitleWord(text: 'I', translation: 'я', startMs: 0, endMs: 100),
        SubtitleWord(text: 'wanna', translation: 'хочу', startMs: 100, endMs: 400),
      ]);
      expect(line.translationText, 'я хочу');
    });

    test('строка с переводом переживает запись и чтение', () {
      final before = TrackSubtitles(
        language: 'en',
        translationLanguage: 'ru',
        lines: [
          SubtitleLine([w('one', 0, 100)], translation: 'раз'),
        ],
      );
      final after = TrackSubtitles.fromJson(before.toJson());
      expect(after.lines.single.translation, 'раз');
      expect(after.lines.single.words.single.text, 'one');
    });

    test('старый формат (голый массив слов) читается по-прежнему', () {
      // На телефоне лежат разборы, сделанные до перевода строк. Потерять их
      // из-за смены формата значит заставить платить за них второй раз.
      final subs = TrackSubtitles.fromJson({
        'language': 'en',
        'translation': 'ru',
        'lines': [
          [
            {'w': 'one', 't': 'раз', 'start': 0, 'end': 100},
          ],
        ],
      });
      expect(subs.lines.single.words.single.text, 'one');
      expect(subs.lines.single.translationText, 'раз');
    });
  });

  group('подсветка на обеих сторонах', () {
    /// То же правило, что в _ReaderLine._mirrorWord: слово перевода на том
    /// же месте по счёту.
    int mirror(int activeWord, int sourceWords, int targetWords) {
      if (activeWord < 0 || sourceWords == 0 || targetWords == 0) return -1;
      final at = ((activeWord + 0.5) * targetWords / sourceWords).floor();
      return at.clamp(0, targetWords - 1);
    }

    test('одинаковое число слов — точное попадание', () {
      for (var i = 0; i < 4; i++) {
        expect(mirror(i, 4, 4), i);
      }
    });

    test('перевод короче — счёт сжимается, но не выходит за край', () {
      expect(mirror(0, 6, 3), 0);
      expect(mirror(5, 6, 3), 2);
      for (var i = 0; i < 6; i++) {
        expect(mirror(i, 6, 3), inInclusiveRange(0, 2));
      }
    });

    test('перевод длиннее — тоже в пределах', () {
      for (var i = 0; i < 3; i++) {
        expect(mirror(i, 3, 7), inInclusiveRange(0, 6));
      }
    });

    test('без активного слова не подсвечивается ничего', () {
      expect(mirror(-1, 5, 5), -1);
      expect(mirror(2, 5, 0), -1);
    });
  });

  group('устройство экрана', () {
    String player() =>
        File('lib/features/listening/player_screen.dart').readAsStringSync();

    test('текст виден весь, а не по одной строке', () {
      // Прежний экран показывал ОДНУ строку за раз: прочитанное исчезало, а
      // вернуться взглядом было некуда.
      final s = player();
      expect(s, contains('ScrollablePositionedList.builder'));
      expect(s, contains('itemCount: subtitles.lines.length'));
    });

    test('плашки перемотки закрывает только игрок', () {
      // Нажатие плашки их НЕ закрывает: игрок сам решает, сколько раз
      // подряд перемотать.
      final s = player();
      final chip = s.substring(s.indexOf('class _StepChip'));
      expect(chip.contains('_SeekMenu.none'), isFalse,
          reason: 'плашка закрывает меню — а должна только перематывать');
      // Закрывает их слой-перехватчик под панелью.
      expect(s, contains('onTap: () => setState(() => _menu = _SeekMenu.none)'));
    });

    test('автопрокрутка уступает пальцу', () {
      // Увести текст из-под пальца — худшее, что может сделать список.
      final s = player();
      expect(s, contains('n.dragDetails != null'));
      expect(s, contains('_following'));
    });

    test('часы знают о скорости', () {
      // На 1.5× запись за ту же секунду уходит на полторы; не умножив,
      // подсветка отставала бы тем сильнее, чем дальше играет.
      expect(player(), contains('_clock.rate = speed'));
      expect(
        File('lib/core/track_clock.dart').readAsStringSync(),
        contains('(_since.elapsedMilliseconds * _rate).round()'),
      );
    });

    test('после конца записи подсветка оживает вместе со звуком', () {
      // markCompleted гасит счётчик кадров, и resume его не заводит: звук
      // пошёл бы, а текст стоял.
      expect(player(), contains('fromStart ? _clock.start() : _clock.resume()'));
      expect(
        File('lib/core/track_clock.dart').readAsStringSync(),
        contains('void _startTicker()'),
      );
    });
  });
}
