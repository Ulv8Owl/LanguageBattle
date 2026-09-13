import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'audio_track.dart';

/// Субтитры, притянутые инструментом, — НА УСТРОЙСТВЕ, а не в репозитории.
///
/// ПОЧЕМУ ИМЕННО ТАК. Текст ролика принадлежит его автору: мы его не
/// сочиняли и раздавать вместе с игрой не вправе. Инструмент получает
/// субтитры по ссылке так же, как их получил бы браузер того, кто эту
/// ссылку открыл, и кладёт рядом с треком у него же на телефоне. В сборку
/// и на гит не уходит ничего.
///
/// РАЗМЕТКА ИЗ РЕПОЗИТОРИЯ ГЛАВНЕЕ. Если у трека есть свой файл со словами
/// (его пишет автор трека, вместе с переводами), инструмент не
/// предлагается и притянутое не используется: своя разметка точнее любой
/// автоматической.
class TrackCaptions {
  TrackCaptions._();

  static Future<File> _file(String trackId) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/track_captions/$trackId.json');
  }

  static Future<bool> exists(String trackId) async {
    try {
      final file = await _file(trackId);
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Строки, притянутые для этого трека. null — их ещё нет.
  static Future<List<TrackLine>?> load(String trackId) async {
    try {
      final file = await _file(trackId);
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString());
      final lines = (raw as Map<String, dynamic>)['lines'] as List?;
      if (lines == null || lines.isEmpty) return null;
      return [
        for (final line in lines)
          TrackLine([
            for (final word in (line as List))
              TimedWord.fromJson(Map<String, dynamic>.from(word as Map)),
          ]),
      ];
    } catch (_) {
      // Битый файл — это «субтитров нет»: инструмент откроется снова и
      // перезапишет его. Падать тут не из-за чего.
      return null;
    }
  }

  static Future<void> save({
    required String trackId,
    required String videoId,
    required List<TrackLine> lines,
  }) async {
    final file = await _file(trackId);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'track': trackId,
      'video': videoId,
      'saved_at': DateTime.now().toUtc().toIso8601String(),
      'lines': [
        for (final line in lines) [for (final word in line.words) word.toJson()],
      ],
    }));
  }

  /// Забыть притянутое — чтобы подставить другую ссылку.
  static Future<void> clear(String trackId) async {
    try {
      final file = await _file(trackId);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Нечего удалять или нет прав — результат тот же: субтитров нет.
    }
  }
}
