import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase_client.dart';
import 'library_track.dart';
import 'track_library.dart';
import 'track_subtitles.dart';

/// Разбор не получился. Причина написана словами — её показывают игроку.
class TranscribeFailed implements Exception {
  final String reason;
  const TranscribeFailed(this.reason);

  @override
  String toString() => reason;
}

/// Отдаёт запись игрока модели и забирает пословный разбор с переводом.
///
/// ЗАПИСЬ УЕЗЖАЕТ НА СЕРВЕР ТОЛЬКО НА ВРЕМЯ РАЗБОРА. Модель не умеет читать
/// файл из телефона, поэтому копия кладётся в хранилище, разбирается и
/// удаляется — в том же вызове, включая случай, когда разбор провалился.
/// Результат ложится на устройство игрока: это его файл, разобранный по его
/// же просьбе, и держать у себя нам нечего.
///
/// САМ ФАЙЛ ОСТАЁТСЯ ГДЕ ЛЕЖАЛ. В приложение он не копируется — в списке
/// хранится путь (см. TrackLibrary).
class TrackTranscriber {
  TrackTranscriber._();

  static const String _bucket = 'voice-recordings';
  static const String _function = 'transcribe-track';

  /// Разбирает [track] и сохраняет субтитры. Возвращает обновлённую запись.
  static Future<LibraryTrack> run({
    required LibraryTrack track,
    required String translateTo,
  }) async {
    final file = File(track.path);
    if (!await file.exists()) {
      throw const TranscribeFailed('файла больше нет по прежнему пути');
    }

    final extension = _extensionOf(track.path);
    final storagePath = 'tracks/$currentUserId/${track.id}.$extension';

    try {
      await supabase.storage.from(_bucket).uploadBinary(
            storagePath,
            await file.readAsBytes(),
            fileOptions: const FileOptions(upsert: true),
          );
    } catch (e) {
      throw TranscribeFailed('не удалось отправить запись: $e');
    }

    try {
      final response = await supabase.functions.invoke(
        _function,
        body: {
          'storagePath': storagePath,
          'durationMs': track.durationMs,
          'translateTo': translateTo,
        },
      );

      final data = response.data;
      if (data is! Map) throw const TranscribeFailed('пустой ответ разбора');
      final map = Map<String, dynamic>.from(data);
      final error = map['error'];
      if (error is String && error.isNotEmpty) throw TranscribeFailed(error);

      final subtitles = TrackSubtitles.fromJson({
        'language': map['language'] ?? track.language,
        'translation': map['translation'] ?? translateTo,
        'lines': map['lines'] ?? const [],
      }).normalized();

      if (subtitles.isEmpty) {
        // ПОКАЗЫВАЕМ, ЧТО ПРИШЛО. Разбор к этому месту уже оплачен, и
        // «не нашлось слов» без единой подробности означает ещё одну
        // попытку вслепую — за ту же цену. Кусок ответа отвечает на
        // единственный вопрос, который тут возникает: модель промолчала
        // или ответила не тем.
        final sample = '${map['lines'] ?? map}';
        throw TranscribeFailed(
          'разбор не прочитался. Ответ модели начинается так: '
          '${sample.substring(0, sample.length < 160 ? sample.length : 160)}',
        );
      }

      await SubtitleStore.save(track.id, subtitles);
      final updated = track.copyWith(
        hasSubtitles: true,
        language: subtitles.language.isEmpty ? track.language : subtitles.language,
        translationLanguage: translateTo,
      );
      await TrackLibrary.update(updated);
      return updated;
    } on TranscribeFailed {
      rethrow;
    } on FunctionException catch (e) {
      // ПРИЧИНУ ПИШЕТ СЕРВЕР, И ОНА НАПИСАНА СЛОВАМИ: «нужно 6 энергии, а
      // есть 2», «запись длиннее 12 минут». На любой ответ кроме 2xx клиент
      // бросает исключение, и `'$e'` превращал бы эту фразу в
      // «FunctionsHttpException(status: 402, details: {error: …})» — то
      // есть ровно в то, из чего игрок ничего не поймёт.
      throw TranscribeFailed(_reasonOf(e));
    } catch (e) {
      throw TranscribeFailed('$e');
    } finally {
      // Копия в хранилище больше не нужна НИ В КАКОМ СЛУЧАЕ — ни после
      // удачи, ни после отказа. Оставленная «на потом», она превратилась бы
      // в чужую фонотеку у нас на сервере.
      try {
        await supabase.storage.from(_bucket).remove([storagePath]);
      } catch (_) {
        // Не удалилась — не повод ронять уже готовый разбор.
      }
    }
  }

  /// Фраза сервера из тела отказа. Не нашлась — отвечаем хотя бы кодом.
  static String _reasonOf(FunctionException e) {
    final details = e.details;
    if (details is Map) {
      final reason = details['error'];
      if (reason is String && reason.isNotEmpty) return reason;
    }
    if (details is String && details.isNotEmpty) return details;
    return 'сервер ответил ${e.status}';
  }

  /// Расширение файла: по нему провайдер определяет формат записи.
  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return 'mp3';
    final ext = path.substring(dot + 1).toLowerCase();
    return ext.length > 5 ? 'mp3' : ext;
  }
}
