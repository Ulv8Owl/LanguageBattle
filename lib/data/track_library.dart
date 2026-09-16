import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'library_track.dart';
import 'remote_content.dart';
import 'track_subtitles.dart';

/// Библиотека «Аудирования»: записи игры и записи игрока в одном списке.
///
/// ═══ ПОЧЕМУ ЗАПИСЬ ИГРОКА ВСЁ-ТАКИ КОПИРУЕТСЯ ═══
///
/// Здесь было написано обратное: «в приложение не копируется, запоминается
/// путь». Это оказалось неправдой, и неправдой опасной. Выбор файла на
/// Android идёт через системный выбор документов, который отдаёт не путь, а
/// `content://`-ссылку; плагин сам сохраняет файл в КЕШ приложения
/// (`getCacheDir()/file_picker/<время>/имя`) и возвращает путь туда — см.
/// `FileUtils.openFileStream` в file_picker. То есть копия была всегда,
/// просто не наша, и лежала она там, откуда система вправе стереть её в
/// любой момент без спроса.
///
/// Для игрока это выглядело бы так: запись, добавленная неделю назад и
/// разобранная за его энергию, однажды отвечает «файла больше нет» — хотя
/// он ничего не трогал. И объяснить это ему было бы нечем.
///
/// Поэтому копия делается ЯВНО и в наш собственный каталог
/// (`getApplicationSupportDirectory()/tracks`), где её не сносит никто,
/// кроме нас и очистки данных приложения. Места это стоит ровно одного
/// файла — того самого, который плагин и так уже скопировал, — а взамен
/// путь перестаёт протухать.
///
/// ИСХОДНИК ИГРОКА МЫ НЕ ТРОГАЕМ НИКОГДА: ни читаем повторно, ни удаляем.
/// Убрал запись из фонотеки — удаляется НАША копия (см. [remove]); его
/// файл остаётся там, где лежал.
class TrackLibrary {
  TrackLibrary._();

  /// Каталог наших копий. Рядом с разбором, в данных приложения, а не в
  /// кеше: кеш система чистит по своему усмотрению.
  static Future<Directory> _audioDir() async {
    final dir = await getApplicationSupportDirectory();
    return Directory('${dir.path}/tracks');
  }

  /// Забирает выбранный игроком файл себе и возвращает путь к копии.
  ///
  /// Расширение сохраняем: по нему провайдер определяет формат записи, и
  /// плеер тоже выбирает декодер по нему.
  static Future<String> adopt(String pickedPath, String trackId) async {
    final dir = await _audioDir();
    await dir.create(recursive: true);
    final dot = pickedPath.lastIndexOf('.');
    final ext = dot > 0 && dot < pickedPath.length - 1
        ? pickedPath.substring(dot + 1).toLowerCase()
        : 'mp3';
    final target = File('${dir.path}/$trackId.${ext.length > 5 ? 'mp3' : ext}');
    await File(pickedPath).copy(target.path);
    return target.path;
  }

  /// Список записей игрока. Записи игры приходят из репозитория и здесь не
  /// хранятся — их незачем дублировать на каждом телефоне.
  static Future<File> _registry() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/track_library.json');
  }

  static const String _bundledIndex = 'assets/tracks/index.json';

  /// Всё, что есть: сначала записи игрока (свежие сверху), потом записи
  /// игры. Порядок задан здесь один раз — экран его не переставляет.
  static Future<List<LibraryTrack>> all() async {
    final mine = await uploaded();
    final theirs = await library();
    return [...mine, ...theirs];
  }

  /// Записи игрока. Свежая сверху: последнее добавленное — то, ради чего
  /// игрок сюда и зашёл.
  static Future<List<LibraryTrack>> uploaded() async {
    try {
      final file = await _registry();
      if (!await file.exists()) return const [];
      final raw = jsonDecode(await file.readAsString());
      final tracks = [
        for (final row in (raw as List))
          LibraryTrack.fromJson(Map<String, dynamic>.from(row as Map)),
      ]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
      return tracks;
    } catch (_) {
      return const [];
    }
  }

  /// Записи, пришедшие с игрой. У них субтитры уже есть.
  static Future<List<LibraryTrack>> library() async {
    try {
      final raw = await RemoteContent.loadJson(_bundledIndex);
      return [
        for (final row in (raw as List))
          LibraryTrack.fromJson({
            ...Map<String, dynamic>.from(row as Map),
            'source': 'library',
            'subtitles': true,
          }),
      ];
    } catch (_) {
      // Списка нет вовсе — это не поломка: записей игры может не быть.
      return const [];
    }
  }

  static Future<void> add(LibraryTrack track) async {
    final tracks = [...await uploaded(), track];
    await _write(tracks);
  }

  static Future<void> update(LibraryTrack track) async {
    final tracks = [
      for (final existing in await uploaded())
        if (existing.id == track.id) track else existing,
    ];
    await _write(tracks);
  }

  /// Убрать запись из списка.
  ///
  /// Удаляется НАША копия и наш разбор. Файл, который игрок выбирал, лежит
  /// там же, где лежал: мы его не приносили, и удалять чужое у нас нет
  /// права.
  static Future<void> remove(String trackId) async {
    final before = await uploaded();
    await _write([
      for (final track in before)
        if (track.id != trackId) track,
    ]);
    await SubtitleStore.remove(trackId);

    final ours = (await _audioDir()).path;
    for (final track in before) {
      if (track.id != trackId) continue;
      try {
        final copy = File(track.path);
        // Только то, что лежит в НАШЕМ каталоге. Путь мог остаться от
        // прежних версий и вести куда угодно в телефоне — стереть по нему
        // значит удалить у игрока его собственный файл.
        if (copy.parent.path == ours && await copy.exists()) await copy.delete();
      } catch (_) {
        // Не удалилась — запись из списка всё равно ушла.
      }
    }
  }

  static Future<LibraryTrack?> byId(String id) async {
    for (final track in await all()) {
      if (track.id == id) return track;
    }
    return null;
  }

  /// Пропал ли файл записи. Для записей игры всегда false: они в ассетах.
  static Future<bool> missing(LibraryTrack track) async {
    if (!track.isUploaded) return false;
    try {
      return !await File(track.path).exists();
    } catch (_) {
      return true;
    }
  }

  static Future<void> _write(List<LibraryTrack> tracks) async {
    final file = await _registry();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode([for (final track in tracks) track.toJson()]),
    );
  }
}
