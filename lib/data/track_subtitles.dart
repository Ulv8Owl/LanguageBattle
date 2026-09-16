import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Слово с временем и переводом.
///
/// ОРИГИНАЛ И ПЕРЕВОД ЖИВУТ В ОДНОМ ОБЪЕКТЕ, а не в двух параллельных
/// списках. Два списка модель обязательно рассинхронизирует: пропустит
/// междометие в одном, склеит два слова в другом, — и дальше перевод поедет
/// относительно оригинала до конца записи, причём молча. Пара внутри одного
/// объекта разъехаться не может: либо слово есть целиком, либо его нет.
class SubtitleWord {
  final String text;
  final String translation;
  final int startMs;
  final int endMs;

  const SubtitleWord({
    required this.text,
    required this.translation,
    required this.startMs,
    required this.endMs,
  });

  /// Имена полей берём шире, чем просили, и ни одного поля не приводим
  /// жёстко: модель путает `w`/`word`/`text` и изредка присылает время
  /// строкой. Падать на этом нельзя — разбор к тому моменту уже оплачен.
  factory SubtitleWord.fromJson(Map<String, dynamic> json) {
    String text(List<String> keys) {
      for (final key in keys) {
        final value = json[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      return '';
    }

    int ms(List<String> keys) {
      for (final key in keys) {
        final value = json[key];
        if (value is num) return value.toInt();
        if (value is String) {
          final parsed = num.tryParse(value);
          if (parsed != null) return parsed.toInt();
        }
      }
      return 0;
    }

    return SubtitleWord(
      text: text(const ['w', 'word', 'text']),
      translation: text(const ['t', 'translation', 'tr']),
      startMs: ms(const ['start', 'begin', 'from']),
      endMs: ms(const ['end', 'stop', 'to']),
    );
  }

  Map<String, dynamic> toJson() =>
      {'w': text, 't': translation, 'start': startMs, 'end': endMs};
}

/// Строка — то, что показывается на экране разом.
class SubtitleLine {
  final List<SubtitleWord> words;

  const SubtitleLine(this.words);

  int get startMs => words.isEmpty ? 0 : words.first.startMs;

  int get endMs => words.isEmpty ? 0 : words.last.endMs;

  factory SubtitleLine.fromJson(List<dynamic> json) => SubtitleLine([
        for (final word in json)
          if (word is Map) SubtitleWord.fromJson(Map<String, dynamic>.from(word)),
      ]);
}

/// Разбор записи целиком.
class TrackSubtitles {
  final String language;
  final String translationLanguage;
  final List<SubtitleLine> lines;

  const TrackSubtitles({
    required this.language,
    required this.translationLanguage,
    required this.lines,
  });

  List<SubtitleWord> get words => [for (final line in lines) ...line.words];

  int get durationMs => lines.isEmpty ? 0 : lines.last.endMs;

  bool get isEmpty => lines.isEmpty;

  /// Строки из того, что пришло, КАКОЙ БЫ ГЛУБИНЫ ОНО НИ БЫЛО.
  ///
  /// Формат ответа задан в запросе к модели, но задан — не значит соблюдён:
  /// живой разбор вернул строки на уровень вложеннее, и приложение упало на
  /// приведении типа («type 'List&lt;dynamic&gt;' is not a subtype of type
  /// 'Map&lt;dynamic, dynamic&gt;'»), выбросив уже оплаченный разбор целиком.
  ///
  /// Приводит ответ к канону сервер, и здесь это НЕ ДУБЛИРОВАНИЕ: сервер в
  /// проекте один на все ветки, и приложение вполне может разговаривать с
  /// функцией, задеплоенной из другой. Падать на этом оно не должно ни в
  /// каком случае.
  /// Слово ли это. Именно СЛОВО, а не любой объект: {"words": […]} тоже
  /// Map, и приняв его за слово, разбор теряет всё, что внутри.
  static bool _isWord(dynamic node) {
    if (node is! Map) return false;
    for (final key in const ['w', 'word', 'text']) {
      final value = node[key];
      if (value is String && value.trim().isNotEmpty) return true;
    }
    return false;
  }

  static List<SubtitleLine> _linesOf(dynamic node) {
    if (node is List) {
      if (node.isEmpty) return const [];
      // Массив, все элементы которого — слова, это строка; любой другой —
      // список строк, и в него надо спуститься.
      if (node.every(_isWord)) {
        final line = SubtitleLine.fromJson(node);
        return line.words.isEmpty ? const [] : [line];
      }
      return [for (final item in node) ..._linesOf(item)];
    }
    if (node is Map) {
      if (_isWord(node)) {
        return [SubtitleLine.fromJson([node])];
      }
      return [
        for (final value in node.values)
          if (value is List) ..._linesOf(value),
      ];
    }
    return const [];
  }

  factory TrackSubtitles.fromJson(Map<String, dynamic> json) => TrackSubtitles(
        language: (json['language'] as String?) ?? '',
        translationLanguage: (json['translation'] as String?) ?? '',
        lines: _linesOf(json['lines']),
      );

  Map<String, dynamic> toJson() => {
        'language': language,
        'translation': translationLanguage,
        'lines': [
          for (final line in lines) [for (final word in line.words) word.toJson()],
        ],
      };

  /// Приводит разбор в порядок, прежде чем им пользоваться.
  ///
  /// МОДЕЛЬ ОШИБАЕТСЯ ПРЕДСКАЗУЕМО: изредка выдаёт слово с нулевой длиной,
  /// перекрывает соседей или сбивает порядок на стыке строк. Поиск
  /// активного слова двоичный и молча врёт на неотсортированном списке —
  /// дешевле починить здесь один раз, чем ловить потом на экране.
  TrackSubtitles normalized() {
    final cleanLines = <SubtitleLine>[];
    var previousEnd = 0;
    for (final line in lines) {
      final words = <SubtitleWord>[];
      for (final word in line.words) {
        if (word.text.isEmpty) continue;
        final start = word.startMs < previousEnd ? previousEnd : word.startMs;
        final end = word.endMs > start ? word.endMs : start + 120;
        words.add(SubtitleWord(
          text: word.text,
          translation: word.translation,
          startMs: start,
          endMs: end,
        ));
        previousEnd = end;
      }
      if (words.isNotEmpty) cleanLines.add(SubtitleLine(words));
    }
    return TrackSubtitles(
      language: language,
      translationLanguage: translationLanguage,
      lines: cleanLines,
    );
  }
}

/// Разбор лежит НА УСТРОЙСТВЕ, рядом с записью игрока.
///
/// Это его файл, разобранный по его же просьбе; ни звук, ни расшифровка в
/// репозиторий и на сервер не уезжают — сервер видит запись только на время
/// разбора и тут же её забывает.
class SubtitleStore {
  SubtitleStore._();

  static Future<File> _file(String trackId) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/track_subtitles/$trackId.json');
  }

  static Future<TrackSubtitles?> load(String trackId) async {
    try {
      final file = await _file(trackId);
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString());
      final parsed =
          TrackSubtitles.fromJson(Map<String, dynamic>.from(raw as Map)).normalized();
      return parsed.isEmpty ? null : parsed;
    } catch (_) {
      // Битый файл — это «разбора нет»: запись просто попросит разобрать её
      // заново. Падать тут не из-за чего.
      return null;
    }
  }

  static Future<void> save(String trackId, TrackSubtitles subtitles) async {
    final file = await _file(trackId);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(subtitles.toJson()));
  }

  static Future<void> remove(String trackId) async {
    try {
      final file = await _file(trackId);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Нечего удалять или нет прав — результат тот же.
    }
  }
}
