import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/core/track_clock.dart';
import 'package:language_battle/data/audio_track.dart';
import 'package:language_battle/data/word_dictionary.dart';
import 'package:language_battle/data/youtube_captions.dart';

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

  group('ссылка на ролик', () {
    test('разбирается в любой из привычных форм', () {
      // Форм ссылки больше, чем кажется, и своя регулярка ошибалась бы на
      // каждой третьей — поэтому разбор отдан библиотеке, а тест сторожит,
      // что он вообще работает.
      const id = 'dQw4w9WgXcQ';
      for (final input in [
        'https://www.youtube.com/watch?v=$id',
        'https://youtu.be/$id',
        'https://www.youtube.com/embed/$id',
        '  https://m.youtube.com/watch?v=$id&t=42s  ',
        id,
      ]) {
        expect(YoutubeCaptions.videoIdFrom(input), id, reason: input);
      }
    });

    test('мусор не притворяется ссылкой', () {
      expect(YoutubeCaptions.videoIdFrom(''), isNull);
      expect(YoutubeCaptions.videoIdFrom('просто текст'), isNull);
      expect(YoutubeCaptions.videoIdFrom('https://example.com/video'), isNull);
    });
  });

  group('своя разметка главнее притянутой', () {
    test('withLines подставляет слова и пересчитывает длину', () {
      // Притянутое подставляется ТОЛЬКО когда своих слов нет: свою
      // разметку писал человек, знающий и запись, и оба языка.
      const empty = AudioTrack(
        id: 'x',
        title: 't',
        author: '',
        audioAsset: 'tracks/x.mp3',
        language: 'en',
        translationLanguage: 'ru',
        durationMs: 0,
        lines: [],
      );
      expect(empty.lines, isEmpty);

      final filled = empty.withLines(const [
        TrackLine([
          TimedWord(text: 'one', translation: 'один', startMs: 0, endMs: 500),
          TimedWord(text: 'two', translation: null, startMs: 500, endMs: 1200),
        ]),
      ]);
      expect(filled.words.length, 2);
      expect(filled.durationMs, 1200);
      // Всё остальное — то же самое: подставляются слова, а не трек целиком.
      expect(filled.audioAsset, 'tracks/x.mp3');
      expect(filled.title, 't');
    });
  });

  group('перевод — свойство игрока, а не записи', () {
    const track = AudioTrack(
      id: 'x',
      title: 't',
      author: '',
      audioAsset: 'tracks/x.mp3',
      language: 'en',
      translationLanguage: 'ru',
      durationMs: 0,
      lines: [
        TrackLine([
          TimedWord(text: 'one', translation: 'один', startMs: 0, endMs: 500),
        ]),
      ],
    );

    test('своя разметка на нужном языке не трогается', () {
      // Её писал человек, знающий и запись, и оба языка: банк слов её не
      // переплюнет.
      final same = track.localizedFor('ru', const _EmptyDictionary());
      expect(identical(same, track), isTrue);
      expect(same.words.single.translation, 'один');
    });

    test('на чужом языке разметка уступает банку', () {
      // Английская запись нужна и испанцу; русские переводы ему бесполезны,
      // а текст и тайминг — те же самые.
      final other = track.localizedFor('es', const _StubDictionary({'one': 'uno'}));
      expect(other.words.single.translation, 'uno');
      expect(other.words.single.text, 'one', reason: 'текст не меняется');
      expect(other.words.single.startMs, 0, reason: 'тайминг не меняется');
    });

    test('чего нет в банке — остаётся без перевода', () {
      // Пустое место честнее выдуманного слова.
      final other = track.localizedFor('es', const _StubDictionary({}));
      expect(other.words.single.translation, isNull);
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


/// Словарь-заглушка: настоящий читает банк слов с диска, а проверяем мы
/// правило подстановки, а не банк.
class _StubDictionary implements WordDictionary {
  final Map<String, String> _words;

  const _StubDictionary(this._words);

  @override
  String? translate(String word) => _words[word.toLowerCase()];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyDictionary extends _StubDictionary {
  const _EmptyDictionary() : super(const {});
}
