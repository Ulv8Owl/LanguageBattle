import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/core/track_clock.dart';
import 'package:language_battle/data/audio_track.dart';
import 'package:language_battle/data/track_glossary.dart';
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

  group('слово наверху без украшений', () {
    TimedWord word(String text, [String? translation]) =>
        TimedWord(text: text, translation: translation, startMs: 0, endMs: 1);

    test('скобки, ноты и знаки препинания срезаются', () {
      // Внизу, в сплошном тексте, это читается нормально: видно строку
      // целиком. Наверху слово стоит одно и во весь экран.
      expect(word('(Hello').displayText, 'Hello');
      expect(word('world,').displayText, 'world');
      expect(word('♪').displayText, '');
      expect(word('«Привет!»').displayText, 'Привет');
      expect(word('[test]').displayText, 'test');
    });

    test('дефис и апостроф внутри слова остаются', () {
      // Они часть слова, а не украшение.
      expect(word("don't").displayText, "don't");
      expect(word('п-п-покер').displayText, 'п-п-покер');
      // А по краям — срезаются.
      expect(word('-край-').displayText, 'край');
    });

    test('перевод чистится так же', () {
      // Скобка под словом выглядит так же странно, как скобка в слове.
      expect(word('x', '(перевод)').displayTranslation, 'перевод');
      expect(word('x').displayTranslation, '');
    });

    test('сам текст не меняется — чистится только показ', () {
      // Внизу строка должна остаться такой, какой её написали.
      final w = word('(Hello,');
      expect(w.text, '(Hello,');
      expect(w.displayText, 'Hello');
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

  group('словарь трека', () {
    test('разделителем годится равенство, табуляция и дефис с пробелами', () {
      // Файл правят руками, и требовать ровно один символ — значит ловить
      // опечатки вместо переводов.
      final g = TrackGlossary.parse('''
alpha = первый
beta	второй
gamma - третий
delta — четвёртый
''');
      expect(g.byIndex, ['первый', 'второй', 'третий', 'четвёртый']);
    });

    test('дефис внутри слова не принимается за разделитель', () {
      // Пробелы вокруг — единственное, чем настоящий разделитель отличается
      // от дефиса в самом слове.
      final g = TrackGlossary.parse('x-y-z = игрек');
      expect(g.at(0), 'игрек');
    });

    test('пустые строки и комментарии не сдвигают нумерацию', () {
      // Один случайный перенос строки развалил бы весь перевод, начиная с
      // него.
      final g = TrackGlossary.parse('''
# заголовок

alpha = первый

# ещё комментарий
beta = второй
''');
      expect(g.byIndex, ['первый', 'второй']);
    });

    test('пустой перевод — это «перевода нет»', () {
      final g = TrackGlossary.parse('the =\nalpha = первый\nbeta');
      expect(g.at(0), isNull);
      expect(g.at(1), 'первый');
      expect(g.at(2), isNull, reason: 'строка без разделителя — тоже пусто');
      expect(g.at(99), isNull, reason: 'за пределами словаря');
    });

    test('заготовка перечисляет слова по порядку', () {
      final text = TrackGlossary.template('t', ['alpha', 'beta']);
      expect(text, contains('alpha = '));
      expect(text, contains('beta = '));
      // И читается обратно как пустой словарь той же длины.
      expect(TrackGlossary.parse(text).byIndex, [null, null]);
    });
  });

  group('словарь трека главнее банка', () {
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
          TimedWord(text: 'one', translation: 'из банка', startMs: 0, endMs: 1),
          TimedWord(text: 'two', translation: 'из банка', startMs: 1, endMs: 2),
        ]),
        TrackLine([
          TimedWord(text: 'one', translation: 'из банка', startMs: 2, endMs: 3),
        ]),
      ],
    );

    test('слова сопоставляются по порядку, а не по тексту', () {
      // Одно и то же слово в разных местах значит разное; по тексту их не
      // различить, а по месту — всегда.
      final out = track.glossed(const TrackGlossary(['первое', null, 'третье']));
      expect(out.words.map((w) => w.translation), ['первое', 'из банка', 'третье']);
    });

    test('недописанный словарь не отбирает найденное', () {
      // Пустая строка означает «перевода нет», а не «сотри то, что было».
      final out = track.glossed(const TrackGlossary(['первое']));
      expect(out.words[1].translation, 'из банка');
      expect(out.words[2].translation, 'из банка');
    });

    test('текст и тайминг словарь не трогает', () {
      final out = track.glossed(const TrackGlossary(['первое', 'второе', 'третье']));
      expect(out.words.map((w) => w.text), ['one', 'two', 'one']);
      expect(out.words.map((w) => w.startMs), [0, 1, 2]);
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
