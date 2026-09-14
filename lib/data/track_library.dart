import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'library_track.dart';
import 'remote_content.dart';
import 'track_subtitles.dart';

/// Библиотека «Аудирования»: записи игры и записи игрока в одном списке.
///
/// ЗАПИСИ ИГРОКА НЕ КОПИРУЮТСЯ В ПРИЛОЖЕНИЕ. Запоминается путь к файлу в
/// памяти телефона — по нему и играем. Копия удвоила бы место на диске
/// ради ничего: файл уже лежит у игрока, и он сам решает, когда его
/// удалить.
///
/// ОТСЮДА И СЛАБОЕ МЕСТО, О КОТОРОМ ЧЕСТНЕЕ ЗНАТЬ: файл могут удалить или
/// перенести мимо нас. Список это переживает — запись остаётся видна, но
/// при попытке играть честно скажет, что файла больше нет (см. [missing]).
class TrackLibrary {
  TrackLibrary._();

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

  /// Убрать запись из списка. Сам файл игрока НЕ трогаем: мы его не
  /// приносили, и удалять чужое у нас нет права.
  static Future<void> remove(String trackId) async {
    await _write([
      for (final track in await uploaded())
        if (track.id != trackId) track,
    ]);
    await SubtitleStore.remove(trackId);
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
