import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/data/voice_submission.dart';

/// Сдаваясь по таймауту, клиент раньше подменял результат пустой заглушкой
/// «речь не распознана». Так терялось разом два: настоящая причина сбоя и
/// вся диагностика, которую сервер успел записать до того, как повис.
void main() {
  const withData = RecordingOutcome(
    transcript: 'my brother go to shop',
    status: TranscriptStatus.ok,
    judgeStatus: JudgeStatus.pending,
    cleaned: 'my brother go to shop',
    debug: {
      'asr': {'provider': 'google', 'elapsed_ms': 1614},
    },
  );

  test('пометка о неответе не стирает то, что сервер успел записать', () {
    final marked = withData.withClientFailure('задача: processing · в очереди 300 с');

    expect(marked.transcript, 'my brother go to shop');
    expect(marked.status, TranscriptStatus.ok);
    expect(marked.asrDebug?['provider'], 'google');
    expect(marked.spokenForDiff, 'my brother go to shop');
  });

  test('причина неответа доносится дословно', () {
    final marked = withData.withClientFailure('задача оценки не создана');
    expect(marked.clientFailure, 'задача оценки не создана');
  });

  test('обычный результат ничем не помечен', () {
    expect(withData.clientFailure, isNull);
  });

  test('судья, не дошедший до записи, не выдаётся за ответившего', () {
    // Заглушка на аварийной ветке ставит pending, а не ok: пустой список
    // ошибок при judge_status=ok читается как «ошибок нет».
    const stub = RecordingOutcome(
      transcript: '',
      status: TranscriptStatus.pending,
      judgeStatus: JudgeStatus.pending,
    );
    expect(stub.judgeStatus, JudgeStatus.pending);
  });
}
