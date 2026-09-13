import 'remote_content.dart';

/// Трек режима «Аудирование»: звук в самой игре плюс текст, у которого
/// КАЖДОЕ СЛОВО знает своё время и свой перевод.
///
/// ПОЧЕМУ ПОСЛОВНО, А НЕ ПОСТРОЧНО. Обычные субтитры размечены строками —
/// этого хватает, чтобы читать, и не хватает здесь: весь режим держится на
/// том, что подсвечено ровно то слово, которое звучит сейчас, и что сверху
/// висит его перевод. Строки на телефоне длинные, и подсветка целой строки
/// не отвечает на единственный вопрос игрока — «какое из этих слов я
/// только что услышал».
///
/// ПЕРЕВОД ЛЕЖИТ В САМОМ ТРЕКЕ, А НЕ ИЩЕТСЯ В БАНКЕ СЛОВ. Банк знает
/// словарную форму и одно значение на слово; в живой речи слово стоит в
/// форме, которой там нет, и значит ровно то, что значит в этой строке.
/// Перевод — часть разметки трека, его пишет тот, кто трек размечает.
class TimedWord {
  final String text;

  /// Перевод на родной язык игрока. null — перевода нет, слово
  /// подсвечивается, но сверху под ним пусто.
  final String? translation;

  final int startMs;
  final int endMs;

  const TimedWord({
    required this.text,
    required this.translation,
    required this.startMs,
    required this.endMs,
  });

  int get durationMs => endMs - startMs;

  factory TimedWord.fromJson(Map<String, dynamic> json) => TimedWord(
        text: (json['w'] as String?) ?? '',
        translation: json['t'] as String?,
        startMs: (json['start'] as num?)?.toInt() ?? 0,
        endMs: (json['end'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'w': text,
        't': translation,
        'start': startMs,
        'end': endMs,
      };
}

/// Строка текста — ею же он и рисуется внизу экрана.
class TrackLine {
  final List<TimedWord> words;

  const TrackLine(this.words);

  int get startMs => words.isEmpty ? 0 : words.first.startMs;

  int get endMs => words.isEmpty ? 0 : words.last.endMs;
}

class AudioTrack {
  final String id;
  final String title;
  final String author;

  /// Путь звука ВНУТРИ ИГРЫ, от папки assets: 'tracks/имя.mp3'.
  ///
  /// Ссылок наружу здесь нет намеренно. Внешний источник может исчезнуть,
  /// заблокироваться или замедлиться ровно в тот момент, когда режим уже
  /// начался, — а файл в приложении играет всегда и одинаково.
  final String audioAsset;

  /// Язык трека — тот, который игрок учит.
  final String language;

  /// Язык переводов в разметке. Трек, размеченный на русский, испанцу
  /// показывать нечего.
  final String translationLanguage;

  final int durationMs;
  final List<TrackLine> lines;

  const AudioTrack({
    required this.id,
    required this.title,
    required this.author,
    required this.audioAsset,
    required this.language,
    required this.translationLanguage,
    required this.durationMs,
    required this.lines,
  });

  /// Все слова подряд, в порядке звучания. Текст рисуется строками, а
  /// активное слово ищется по этому списку.
  List<TimedWord> get words => [for (final line in lines) ...line.words];

  factory AudioTrack.fromJson(Map<String, dynamic> json) {
    final lines = [
      for (final line in (json['lines'] as List? ?? const []))
        TrackLine([
          for (final word in (line as List))
            TimedWord.fromJson(Map<String, dynamic>.from(word as Map)),
        ]),
    ];
    return AudioTrack(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? 'Без названия',
      author: (json['author'] as String?) ?? '',
      audioAsset: (json['audio'] as String?) ?? '',
      language: (json['language'] as String?) ?? 'en',
      translationLanguage: (json['translation'] as String?) ?? 'ru',
      // Длительность не обязана быть в файле: последнее слово знает её не
      // хуже, а лишнее поле однажды разойдётся с разметкой.
      durationMs: (json['duration'] as num?)?.toInt() ??
          (lines.isEmpty ? 0 : lines.last.endMs),
      lines: lines,
    );
  }
}

/// Каталог треков. Список и разметка лежат в репозитории и тянутся тем же
/// путём, что фразы и слова (RemoteContent); сам звук — в ассетах сборки.
class TrackCatalog {
  TrackCatalog._();

  static const String indexPath = 'assets/tracks/index.json';

  static String trackPath(String id) => 'assets/tracks/$id.json';

  /// Все треки. Битый или недоступный молча пропускается: один сломанный
  /// файл не должен закрывать режим целиком.
  static Future<List<AudioTrack>> all() async {
    final index = await RemoteContent.loadJson(indexPath);
    final tracks = <AudioTrack>[];
    for (final entry in (index as List)) {
      final id = entry is String ? entry : (entry as Map)['id'] as String?;
      if (id == null) continue;
      try {
        tracks.add(await load(id));
      } catch (_) {
        continue;
      }
    }
    return tracks;
  }

  static Future<AudioTrack> load(String id) async {
    final raw = await RemoteContent.loadJson(trackPath(id));
    return AudioTrack.fromJson(Map<String, dynamic>.from(raw as Map));
  }
}
