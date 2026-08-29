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

/// Отработал ли LLM-судья по этой записи. Значения совпадают со столбцом
/// voice_recordings.judge_status (миграция 0014).
enum JudgeStatus {
  /// Задача ещё не дошла до судьи.
  pending,

  /// Судья ответил: пустой список ошибок здесь и правда значит «ошибок нет».
  ok,

  /// Судья не ответил или ответил мусором — балл нейтральный, а пустой
  /// список ошибок НЕ значит, что ошибок нет.
  degraded,

  /// Судью не звали: речь не распознана либо это родной слот Дуэли.
  skipped;

  static JudgeStatus parse(String? value) => switch (value) {
        'ok' => JudgeStatus.ok,
        'degraded' => JudgeStatus.degraded,
        'skipped' => JudgeStatus.skipped,
        _ => JudgeStatus.pending,
      };
}

/// Что сервер в итоге разобрал по загруженной записи.
class RecordingOutcome {
  final String transcript;
  final TranscriptStatus status;
  final JudgeStatus judgeStatus;

  /// Ответ игрока целиком, исправленный судьёй (миграция 0017). Пустая
  /// строка — сравнивать не с чем: судья не отвечал или не прислал правку.
  final String corrected;

  /// Что игрок сказал, за вычетом брошенных вариантов и повторов (миграция
  /// 0018). Именно с ним сравнивается [corrected]: если сравнивать с
  /// исходным текстом, самоисправление подсветилось бы как ошибка.
  final String cleaned;

  /// Техническая диагностика пайплайна: что ответили ASR и судья
  /// (voice_recordings.pipeline_debug, миграция 0016). Показывается на
  /// экране, пока включён kShowPipelineDebug.
  final Map<String, dynamic>? debug;

  const RecordingOutcome({
    required this.transcript,
    required this.status,
    this.judgeStatus = JudgeStatus.ok,
    this.corrected = '',
    this.cleaned = '',
    this.debug,
  });

  /// Текст, с которым сравнивается исправленный вариант: очищенный от
  /// самоисправлений, если судья его прислал, иначе — что услышал ASR.
  String get spokenForDiff => cleaned.isNotEmpty ? cleaned : transcript;

  /// true — судья не ответил потому, что ПРОВАЙДЕР отказал по своему
  /// лимиту (дневной бюджет, квота, rate limit). Это не наша поломка, и
  /// говорить игроку «сбой на нашей стороне» в таком случае неверно.
  bool get judgeHitProviderLimit => judgeDebug?['provider_limit'] == true;

  Map<String, dynamic>? get asrDebug => _section('asr');
  Map<String, dynamic>? get judgeDebug => _section('judge');

  /// Какой попыткой сервер счёл эту запись и какой режим разбора выбрал.
  /// Без этого «вторая попытка получила подробные объяснения» неотличимо
  /// от исправной работы — ровно на этом баг и прятался.
  Map<String, dynamic>? get roundDebug => _section('round');

  Map<String, dynamic>? _section(String key) {
    final value = debug?[key];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }
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
///
/// [attemptNumber] — какая это попытка в раунде (в PvP всегда 1). Сервер по
/// нему решает, просить ли у судьи развёрнутые объяснения, и вычислять его
/// подсчётом строк оказалось ненадёжно: сбой счётчика молча выдавал вторую
/// попытку за первую. Клиент этот номер и так знает — он в имени файла.
Future<String> submitVoiceRecording({
  required String filePath,
  required String storagePath,
  required String userId,
  required String languageCode,
  required String recordingSlot,
  required double durationSeconds,
  String? roundId,
  String? trainingRoundId,
  int attemptNumber = 1,
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
        'attempt_number': attemptNumber,
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
      .select('transcript, transcript_status, judge_status, corrected_text, cleaned_text, pipeline_debug')
      .eq('id', recordingId)
      .maybeSingle();
  return RecordingOutcome(
    transcript: ((row?['transcript'] as String?) ?? '').trim(),
    status: TranscriptStatus.parse(row?['transcript_status'] as String?),
    judgeStatus: JudgeStatus.parse(row?['judge_status'] as String?),
    corrected: ((row?['corrected_text'] as String?) ?? '').trim(),
    cleaned: ((row?['cleaned_text'] as String?) ?? '').trim(),
    debug: row?['pipeline_debug'] is Map
        ? Map<String, dynamic>.from(row!['pipeline_debug'] as Map)
        : null,
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
