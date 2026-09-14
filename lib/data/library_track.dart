/// Запись в библиотеке «Аудирования».
///
/// ДВА ВИДА ЗАПИСЕЙ, И РАЗНИЦА МЕЖДУ НИМИ НЕ КОСМЕТИЧЕСКАЯ. Запись
/// библиотеки приходит вместе с игрой: у неё уже есть субтитры и перевод, и
/// играть её можно сразу. Запись игрока лежит у него в телефоне, в
/// приложение НЕ копируется — запоминается путь, — и субтитров у неё нет,
/// пока их не разберёт модель.
enum TrackSource {
  /// Пришла с игрой: субтитры готовы.
  library,

  /// Файл игрока: играем по пути, субтитры разбираем сами.
  uploaded,
}

class LibraryTrack {
  final String id;
  final String title;

  /// Исполнитель или источник. Пусто — показываем только название.
  final String artist;

  final TrackSource source;

  /// Где лежит звук. Для библиотеки — путь ассета, для загруженной — путь в
  /// памяти телефона.
  final String path;

  final int durationMs;

  /// Язык записи и язык перевода — их называет тот, кто её разбирал.
  final String language;
  final String translationLanguage;

  /// Разобрана ли запись. Пока нет — играть нечего, и в списке это видно.
  final bool hasSubtitles;

  /// Когда добавлена. Загруженные стоят выше, и порядок между ними — по
  /// свежести: последняя добавленная сверху.
  final DateTime addedAt;

  const LibraryTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.source,
    required this.path,
    required this.durationMs,
    required this.language,
    required this.translationLanguage,
    required this.hasSubtitles,
    required this.addedAt,
  });

  bool get isUploaded => source == TrackSource.uploaded;

  /// «3:07» — как в любом плеере.
  String get lengthLabel {
    final seconds = durationMs ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  LibraryTrack copyWith({bool? hasSubtitles, String? language, String? translationLanguage}) =>
      LibraryTrack(
        id: id,
        title: title,
        artist: artist,
        source: source,
        path: path,
        durationMs: durationMs,
        language: language ?? this.language,
        translationLanguage: translationLanguage ?? this.translationLanguage,
        hasSubtitles: hasSubtitles ?? this.hasSubtitles,
        addedAt: addedAt,
      );

  factory LibraryTrack.fromJson(Map<String, dynamic> json) => LibraryTrack(
        id: (json['id'] as String?) ?? '',
        title: (json['title'] as String?) ?? 'Без названия',
        artist: (json['artist'] as String?) ?? '',
        source: (json['source'] as String?) == 'library'
            ? TrackSource.library
            : TrackSource.uploaded,
        path: (json['path'] as String?) ?? '',
        durationMs: (json['duration'] as num?)?.toInt() ?? 0,
        language: (json['language'] as String?) ?? '',
        translationLanguage: (json['translation'] as String?) ?? '',
        hasSubtitles: json['subtitles'] as bool? ?? false,
        addedAt: DateTime.tryParse((json['added_at'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'source': source == TrackSource.library ? 'library' : 'uploaded',
        'path': path,
        'duration': durationMs,
        'language': language,
        'translation': translationLanguage,
        'subtitles': hasSubtitles,
        'added_at': addedAt.toUtc().toIso8601String(),
      };
}

/// Сколько энергии стоит разобрать запись.
///
/// ОДНА ЕДИНИЦА ЗА КАЖДЫЕ НАЧАТЫЕ ПОЛМИНУТЫ. Модель берёт деньги за
/// длительность, и цена обязана расти вместе с ней — иначе часовая запись
/// стоила бы столько же, сколько десятисекундная. Полминуты — шаг, который
/// игрок может посчитать в уме, глядя на длину трека.
///
/// ТА ЖЕ ФОРМУЛА ПОВТОРЕНА НА СЕРВЕРЕ (supabase/functions/transcribe-track).
/// Дублирование вынужденное: здесь её показывают ДО подтверждения, там —
/// списывают. Разойдясь, они покажут одну цену, а возьмут другую.
int transcriptionEnergyCost(int durationMs) {
  if (durationMs <= 0) return 1;
  final halfMinutes = (durationMs + 29999) ~/ 30000;
  return halfMinutes < 1 ? 1 : halfMinutes;
}
