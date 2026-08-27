import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../core/audio_format.dart';
import '../core/supabase_client.dart';

/// Итог распознавания речи по одной записи. Значения совпадают со
/// столбцом voice_recordings.transcript_status (миграция 0013) — клиент
/// не решает, что произошло, он только читает решение сервера.
enum TranscriptStatus {
  /// Воркер ещё не дошёл до распознавания.
  pending,

  /// Речь распознана, транскрипт непустой.
  ok,

  /// ASR отработал, но речи не услышал — игрок промолчал или было слишком шумно.
  empty,

  /// Распознать не удалось по вине сервиса — за это игрока не штрафуют.
  failed;

  static TranscriptStatus parse(String? value) => switch (value) {
        'ok' => TranscriptStatus.ok,
        'empty' => TranscriptStatus.empty,
        'failed' => TranscriptStatus.failed,
        _ => TranscriptStatus.pending,
      };
}

/// Что сервер в итоге разобрал по загруженной записи.
class RecordingOutcome {
  final String transcript;
  final TranscriptStatus status;

  const RecordingOutcome({required this.transcript, required this.status});
}

/// Отправка голосового: файл в Storage -> строка в voice_recordings ->
/// задача в evaluation_jobs. Дальше клиент только слушает Realtime и
/// синхронно ничего не ждёт (раздел 9.8).
///
/// Шаги одинаковы для всех трёх режимов и раньше были продублированы в
/// экранах боя и Одиночной Игры — расхождение между копиями означало бы,
/// что один из режимов молча перестал оцениваться.
///
/// Транскрипт здесь СОЗНАТЕЛЬНО не передаётся: речь распознаёт сервер по
/// самому аудио (см. supabase/functions/_shared/transcribeAudio.ts).
/// Ровно один из roundId/trainingRoundId должен быть непустым — это же
/// требование стоит CHECK-constraint'ом на таблице.
Future<String> submitVoiceRecording({
  required String filePath,
  required String storagePath,
  required String userId,
  required String languageCode,
  required String recordingSlot,
  required double durationSeconds,
  String? roundId,
  String? trainingRoundId,
}) async {
  assert(
    (roundId == null) != (trainingRoundId == null),
    'у записи должен быть ровно один родитель: раунд боя ИЛИ раунд соло',
  );

  await supabase.storage.from('voice-recordings').upload(
        storagePath,
        File(filePath),
        fileOptions: const FileOptions(upsert: true, contentType: voiceContentType),
      );

  final inserted = await supabase
      .from('voice_recordings')
      .insert({
        'round_id': ?roundId,
        'training_round_id': ?trainingRoundId,
        'user_id': userId,
        'recording_slot': recordingSlot,
        'language_code': languageCode,
        'audio_storage_path': storagePath,
        'duration_seconds': durationSeconds,
      })
      .select('id')
      .single();

  final recordingId = inserted['id'] as String;
  await supabase.from('evaluation_jobs').insert({
    'voice_recording_id': recordingId,
    'status': 'pending',
  });
  return recordingId;
}

/// Что сервер услышал в записи. Вызывается уже после того, как задача
/// оценки дошла до done/failed.
Future<RecordingOutcome> fetchRecordingOutcome(String recordingId) async {
  final row = await supabase
      .from('voice_recordings')
      .select('transcript, transcript_status')
      .eq('id', recordingId)
      .maybeSingle();
  return RecordingOutcome(
    transcript: ((row?['transcript'] as String?) ?? '').trim(),
    status: TranscriptStatus.parse(row?['transcript_status'] as String?),
  );
}

/// Путь в бакете voice-recordings. Схема путей завязана на RLS-политики
/// хранилища (первый сегмент решает, чью запись проверять), поэтому она
/// собирается здесь, а не в каждом экране отдельно.
String battleRecordingPath({
  required String matchId,
  required String roundId,
  required String userId,
  required String slot,
}) =>
    'match/$matchId/$roundId/${userId}_$slot.$voiceFileExtension';

String trainingRecordingPath({
  required String sessionId,
  required String roundId,
  required String userId,
  required int attempt,
}) =>
    'training/$sessionId/$roundId/${userId}_$attempt.$voiceFileExtension';
