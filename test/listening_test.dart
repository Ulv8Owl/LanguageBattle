import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/core/track_clock.dart';
import 'package:language_battle/data/audio_track.dart';

/// «Аудирование»: звук лежит в самой игре, а перевод — в разметке трека.
void main() {
  group('разбор трека', () {
    final raw = jsonEncode({
      'id': 'x',
      'title': 'Название',
      'audio': 'tracks/x.mp3',
      'language': 'en',
      'translation': 'ru',
      'lines': [
        [
          {'w': 'one', 't': 'один', 'start': 0, 'end': 400},
          {'w': 'the', 't': null, 'start': 400, 'end': 700},
        ],
        [
          {'w': 'two', 't': 'два', 'start': 900, 'end': 1300},
        ],
      ],
    });

    test('перевод берётся из файла, а не из банка слов', () {
      // Банк знает словарную форму и одно значение; в треке слово стоит в
      // своей форме и значит то, что значит здесь.
      final track = AudioTrack.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(track.words.map((w) => w.translation), ['один', null, 'два']);
      expect(track.words.length, 3);
    });

    test('звук — путь внутри игры, а не ссылка наружу', () {
      final track = AudioTrack.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(track.audioAsset, 'tracks/x.mp3');
      expect(track.audioAsset.startsWith('http'), isFalse);
    });

    test('длительность берётся из последнего слова, если её не написали', () {
      // Лишнее поле однажды разойдётся с разметкой; последнее слово знает
      // длину не хуже.
      final track = AudioTrack.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(track.durationMs, 1300);
    });
  });

  group('активное слово', () {
    final starts = [0, 400, 900];

    test('до первого слова активного нет', () {
      expect(activeWordIndex(starts, -1), -1);
    });

    test('слово держится в паузе до следующего', () {
      // Гасить подсветку на каждую паузу значит мигать ею всю дорогу.
      expect(activeWordIndex(starts, 700), 1);
      expect(activeWordIndex(starts, 899), 1);
      expect(activeWordIndex(starts, 900), 2);
    });
  });

  group('скорость', () {
    test('смена скорости не сдвигает пройденное', () {
      final clock = TrackClock()..seekTo(10000);
      clock.setRate(0.5);
      expect(clock.positionMs, 10000);
      expect(clock.rate, 0.5);
      clock.dispose();
    });

    test('бессмысленная скорость игнорируется', () {
      final clock = TrackClock();
      clock.setRate(0);
      clock.setRate(-1);
      expect(clock.rate, 1.0);
      clock.dispose();
    });
  });
}
