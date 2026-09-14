import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/core/track_clock.dart';
import 'package:language_battle/data/library_track.dart';
import 'package:language_battle/data/track_subtitles.dart';

/// «Аудирование»: фонотека, разбор записи и две строки на экране.
void main() {
  group('цена разбора', () {
    test('одна единица за каждые начатые полминуты', () {
      // Цена обязана расти вместе с длиной: модель берёт деньги за неё.
      expect(transcriptionEnergyCost(0), 1, reason: 'пустая — всё равно попытка');
      expect(transcriptionEnergyCost(1), 1);
      expect(transcriptionEnergyCost(30000), 1);
      expect(transcriptionEnergyCost(30001), 2, reason: 'начатые, а не полные');
      expect(transcriptionEnergyCost(180000), 6, reason: 'три минуты');
    });

    test('формула совпадает с серверной', () {
      // Дублирование вынужденное: клиент цену показывает, сервер списывает.
      // Разойдясь, они покажут одну, а возьмут другую.
      final server = File('supabase/functions/transcribe-track/index.ts')
          .readAsStringSync();
      expect(server, contains('Math.ceil(durationMs / 30_000)'));
      expect(server, contains('Math.max(1,'));
    });
  });

  group('разбор приводится в порядок', () {
    TrackSubtitles subs(List<List<SubtitleWord>> lines) => TrackSubtitles(
          language: 'en',
          translationLanguage: 'ru',
          lines: [for (final l in lines) SubtitleLine(l)],
        );

    SubtitleWord w(String text, int start, int end) =>
        SubtitleWord(text: text, translation: 'п', startMs: start, endMs: end);

    test('перекрытие соседей разводится', () {
      // Поиск активного слова двоичный и на неотсортированном списке молча
      // врёт — дешевле починить один раз здесь.
      final out = subs([
        [w('one', 0, 500), w('two', 300, 900)],
      ]).normalized();
      final words = out.words;
      expect(words[1].startMs, greaterThanOrEqualTo(words[0].endMs));
    });

    test('нулевая длина получает ненулевую', () {
      final out = subs([
        [w('one', 100, 100)],
      ]).normalized();
      expect(out.words.single.endMs, greaterThan(out.words.single.startMs));
    });

    test('пустые слова и пустые строки выбрасываются', () {
      final out = subs([
        [w('', 0, 100)],
        [w('two', 200, 400)],
      ]).normalized();
      expect(out.lines.length, 1);
      expect(out.words.single.text, 'two');
    });
  });

  group('активный элемент', () {
    final starts = [0, 500, 1200];

    test('до первого активного нет', () {
      expect(activeIndex(starts, -1), -1);
    });

    test('держится в паузе до следующего', () {
      // Гасить подсветку на каждый вдох значит мигать ею всю дорогу.
      expect(activeIndex(starts, 700), 1);
      expect(activeIndex(starts, 1199), 1);
      expect(activeIndex(starts, 1200), 2);
    });

    test('пустой список не роняет поиск', () {
      expect(activeIndex(const [], 100), -1);
    });
  });

  group('запись игрока', () {
    test('в приложение не копируется — хранится путь', () {
      final track = LibraryTrack.fromJson({
        'id': 'x',
        'title': 'Моя запись',
        'source': 'uploaded',
        'path': '/storage/emulated/0/Music/x.mp3',
        'duration': 61000,
        'language': 'en',
        'translation': 'ru',
        'subtitles': false,
      });
      expect(track.isUploaded, isTrue);
      expect(track.path, startsWith('/storage/'));
      expect(track.lengthLabel, '1:01');
      expect(track.hasSubtitles, isFalse);
    });

    test('разбор помечает запись готовой, не трогая путь', () {
      final track = LibraryTrack.fromJson({
        'id': 'x',
        'source': 'uploaded',
        'path': '/a/b.mp3',
        'duration': 1000,
      });
      final done = track.copyWith(hasSubtitles: true, language: 'pl');
      expect(done.hasSubtitles, isTrue);
      expect(done.language, 'pl');
      expect(done.path, '/a/b.mp3');
    });
  });
}
