import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/debug_flags.dart';
import '../../core/game_access.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/phrase_bank.dart';
import '../../data/voice_submission.dart';
import '../../widgets/chrolingo_widgets.dart';
import '../../widgets/voice_recorder_dock.dart';
import '../subscription/paywall_screen.dart';

/// Сколько раундов в одной сессии Одиночной Игры. Спека не фиксирует это
/// число (раздел 2.2 описывает только механику раунда) — берём 5 раундов
/// на одну единицу энергии.
const _roundsPerSession = 5;

enum _Stage {
  starting,
  /// Ждём первую попытку игрока.
  awaitingFirst,
  /// Первая попытка отправлена, ждём разбор от ИИ.
  gradingFirst,
  /// Разбор пришёл, ждём вторую попытку.
  awaitingSecond,
  /// Вторая попытка отправлена, ждём финальный балл.
  gradingSecond,
  /// Балл выставлен, можно идти дальше.
  roundDone,
  /// Все раунды сессии пройдены.
  sessionDone,
  failed,
}

/// Режим 1 «Одиночная Игра» (раздел 2.2) — вне рейтинга, но с реальными
/// наградами, поэтому оценка идёт через тот же серверный пайплайн
/// voice_recordings → evaluation_jobs → Edge Function, что и PvP.
/// Клиентская оценка недопустима ни в одном режиме.
///
/// Раунд: фраза от ИИ → попытка №1 → разбор ошибок → попытка №2 →
/// финальный балл 1-10 (ELO не меняется).
class TrainingScreen extends StatefulWidget {
  const TrainingScreen({super.key});

  @override
  State<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends State<TrainingScreen> {
  final String _myId = currentUserId;
  final _dockKey = GlobalKey<VoiceRecorderDockState>();
  final _feedController = ScrollController();

  _Stage _stage = _Stage.starting;
  String? _error;
  String? _sessionId;
  String _targetLanguage = 'en';

  int _roundNumber = 0;
  String? _roundId;
  String _phrase = '';

  List<Map<String, dynamic>> _firstAttemptErrors = [];

  /// Что сервер услышал в каждой из двух попыток. Нужно, чтобы не выдавать
  /// тишину и сбой распознавания за безупречный ответ — до перехода на
  /// серверный ASR все три случая показывались одинаковым «ошибок не найдено».
  RecordingOutcome? _firstAttempt;
  RecordingOutcome? _secondAttempt;

  int? _finalScore;
  int? _earnedCoins;

  /// История пройденных раундов сессии — рисуется той же лентой.
  final List<_CompletedRound> _history = [];

  /// Порядок фраз на всю сессию, перемешанный один раз при старте — раунды
  /// соло идут строго локально (одна сессия = один клиент), поэтому, в
  /// отличие от PvP, не нужно синхронизировать "уже использованные индексы"
  /// через БД: достаточно перетасовать банк один раз и идти по порядку.
  late final List<int> _phraseOrder = List.generate(PhraseBank.count, (i) => i)..shuffle();

  StreamSubscription? _jobSub;
  StreamSubscription? _roundSub;

  @override
  void initState() {
    super.initState();
    _startSession();
  }

  @override
  void dispose() {
    _jobSub?.cancel();
    _roundSub?.cancel();
    _watchdog?.cancel();
    _feedController.dispose();
    super.dispose();
  }

  Future<void> _startSession() async {
    try {
      final learning = await supabase
          .from('user_languages')
          .select('language_code')
          .eq('user_id', _myId)
          .eq('role', 'learning')
          .eq('is_active', true)
          .limit(1)
          .maybeSingle();
      _targetLanguage = (learning?['language_code'] as String?) ?? 'en';

      // start_training_session проверяет подписку и списывает энергию на
      // сервере — клиент не решает ни то, ни другое.
      final result = await supabase.rpc('start_training_session', params: {
        'p_target_language': _targetLanguage,
      });
      final map = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
      _sessionId = map['session_id'] as String?;
      if (_sessionId == null) throw StateError('start_training_session вернул пустой session_id');
      await _openRound(1);
    } catch (e) {
      if (!mounted) return;
      if (ServerErrors.isSubscriptionRequired(e)) {
        // Пейволл вместо обычного потока — раздел 2.6.
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          await PaywallScreen.show(context, 'Одиночная Игра');
          if (mounted && context.canPop()) context.pop();
        });
        return;
      }
      setState(() {
        _stage = _Stage.failed;
        _error = ServerErrors.isNoEnergy(e)
            ? 'Энергия закончилась. Она восстанавливается со временем — загляни позже.'
            : 'Не удалось начать сессию: $e';
      });
    }
  }

  Future<void> _openRound(int n) async {
    final sessionId = _sessionId!;
    final phraseIndex = _phraseOrder[(n - 1) % _phraseOrder.length];
    final phrase = PhraseBank.textFor(phraseIndex, _targetLanguage);
    final row = await supabase
        .from('training_rounds')
        .insert({'session_id': sessionId, 'round_number': n, 'generated_phrase': phrase})
        .select()
        .single();
    if (!mounted) return;
    setState(() {
      _roundNumber = n;
      _roundId = row['id'] as String;
      _phrase = phrase;
      _firstAttemptErrors = [];
      _firstAttempt = null;
      _secondAttempt = null;
      _finalScore = null;
      _earnedCoins = null;
      _stage = _Stage.awaitingFirst;
    });
    _scrollToBottomSoon();
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_feedController.hasClients) return;
      _feedController.animateTo(
        _feedController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  /// Загрузка попытки: аудио в Storage → voice_recordings → evaluation_jobs.
  /// Дальше клиент только слушает Realtime, синхронно ничего не ждёт.
  Future<void> _sendTake(VoiceTake take) async {
    final roundId = _roundId;
    final sessionId = _sessionId;
    if (roundId == null || sessionId == null) return;
    final attempt = _stage == _Stage.awaitingFirst ? 1 : 2;

    try {
      final recordingId = await submitVoiceRecording(
        filePath: take.filePath,
        storagePath: trainingRecordingPath(
          sessionId: sessionId,
          roundId: roundId,
          userId: _myId,
          attempt: attempt,
        ),
        userId: _myId,
        languageCode: _targetLanguage,
        recordingSlot: 'target',
        durationSeconds: take.durationSeconds,
        trainingRoundId: roundId,
      );

      if (!mounted) return;
      setState(() => _stage = attempt == 1 ? _Stage.gradingFirst : _Stage.gradingSecond);
      _scrollToBottomSoon();

      if (attempt == 1) {
        _watchFirstAttempt(recordingId);
      } else {
        _watchFinalScore(roundId, recordingId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось отправить голосовое: $e')),
        );
      }
      rethrow;
    }
  }

  /// Попытка №1 даёт только разбор ошибок — балл за неё не ставится
  /// (раздел 2.2). Готовность ловим по статусу задачи в очереди.
  void _watchFirstAttempt(String recordingId) {
    _jobSub?.cancel();
    _startWatchdog(() => _giveUpOnFirstAttempt(recordingId));
    _jobSub = supabase
        .from('evaluation_jobs')
        .stream(primaryKey: ['id'])
        .eq('voice_recording_id', recordingId)
        .listen((rows) async {
      if (!mounted || rows.isEmpty) return;
      final jobStatus = rows.first['status'] as String?;
      if (jobStatus != 'done' && jobStatus != 'failed') return;
      _jobSub?.cancel();
      _watchdog?.cancel();

      final outcome = await fetchRecordingOutcome(recordingId);
      final errors = await supabase
          .from('grammar_errors')
          .select()
          .eq('voice_recording_id', recordingId)
          .order('offset_start');
      if (!mounted) return;
      setState(() {
        _firstAttemptErrors = List<Map<String, dynamic>>.from(errors);
        // Задача упала целиком — разбора не будет, но вторую попытку
        // отбирать у игрока не за что.
        _firstAttempt = jobStatus == 'failed'
            ? const RecordingOutcome(transcript: '', status: TranscriptStatus.failed)
            : outcome;
        _stage = _Stage.awaitingSecond;
      });
      _scrollToBottomSoon();
    });
  }

  /// Сколько ждать результат от сервера, прежде чем признать, что он не
  /// придёт. Оценка идёт асинхронно (распознавание + LLM), поэтому запас
  /// большой — но НЕ бесконечный: воркер может быть убит платформой на
  /// середине, и тогда статус задачи не изменится уже никогда, а игрок
  /// смотрит на вечный спиннер. Раньше это был именно вечный спиннер.
  static const _resultTimeout = Duration(seconds: 120);

  Timer? _watchdog;

  void _startWatchdog(void Function() onTimeout) {
    _watchdog?.cancel();
    _watchdog = Timer(_resultTimeout, onTimeout);
  }

  /// Результат по первой попытке так и не пришёл. Освобождаем зависшую
  /// задачу на сервере и пускаем игрока дальше — вторую попытку отбирать
  /// не за что, сбой не его вина.
  Future<void> _giveUpOnFirstAttempt(String recordingId) async {
    _jobSub?.cancel();
    await supabase.rpc('fail_stale_evaluation_jobs', params: {'p_stale_seconds': 60}).catchError((e) {
      debugPrint('fail_stale_evaluation_jobs failed: $e');
      return null;
    });
    if (!mounted) return;
    setState(() {
      _firstAttempt = const RecordingOutcome(transcript: '', status: TranscriptStatus.failed);
      _stage = _Stage.awaitingSecond;
    });
    _scrollToBottomSoon();
  }

  /// То же для второй попытки, но здесь нужен балл — ставим нейтральный,
  /// как и сервер при собственном сбое: наказывать игрока не за что.
  Future<void> _giveUpOnSecondAttempt() async {
    _roundSub?.cancel();
    await supabase.rpc('fail_stale_evaluation_jobs', params: {'p_stale_seconds': 60}).catchError((e) {
      debugPrint('fail_stale_evaluation_jobs failed: $e');
      return null;
    });
    if (!mounted) return;
    setState(() {
      _secondAttempt = const RecordingOutcome(
        transcript: '',
        status: TranscriptStatus.failed,
        judgeStatus: JudgeStatus.degraded,
      );
      _finalScore = _neutralScore;
      _earnedCoins = null;
      _stage = _Stage.roundDone;
    });
    _scrollToBottomSoon();
  }

  /// Тот же нейтральный балл, что ставит сервер при сбое на своей стороне
  /// (NEUTRAL_SCORE в supabase/functions/_shared/evaluateGrammar.ts).
  static const _neutralScore = 7;

  /// Финальный балл за раунд пишет воркер в training_rounds.final_score.
  void _watchFinalScore(String roundId, String recordingId) {
    _roundSub?.cancel();
    _startWatchdog(_giveUpOnSecondAttempt);
    _roundSub = supabase
        .from('training_rounds')
        .stream(primaryKey: ['id'])
        .eq('id', roundId)
        .listen((rows) async {
      if (!mounted || rows.isEmpty) return;
      final score = rows.first['final_score'] as int?;
      if (score == null) return;
      _roundSub?.cancel();
      _watchdog?.cancel();

      final outcome = await fetchRecordingOutcome(recordingId);
      if (mounted) setState(() => _secondAttempt = outcome);

      int? coins;
      try {
        final reward = await supabase.rpc('claim_training_reward', params: {
          'p_training_round_id': roundId,
        });
        if (reward is Map && reward['coins'] != null) {
          coins = (reward['coins'] as num).toInt();
        }
      } catch (e) {
        debugPrint('claim_training_reward failed: $e');
      }

      // Раунд оценён и награда начислена — обе попытки этого раунда больше
      // не нужны, аудио не хранится "про запас" (см. deferred_suggestions.md,
      // пункт 7 — реализовано по отдельному запросу владельца проекта).
      unawaited(_deleteRoundRecordings(roundId));

      if (!mounted) return;
      setState(() {
        _finalScore = score;
        _earnedCoins = coins;
        _stage = _Stage.roundDone;
      });
      _scrollToBottomSoon();
    });
  }

  Future<void> _deleteRoundRecordings(String trainingRoundId) async {
    try {
      final rows = await supabase
          .from('voice_recordings')
          .select('audio_storage_path')
          .eq('training_round_id', trainingRoundId);
      final paths = rows.map((r) => r['audio_storage_path'] as String).toList();
      if (paths.isEmpty) return;
      await supabase.storage.from('voice-recordings').remove(paths);
    } catch (e) {
      debugPrint('failed to delete training round recordings: $e');
    }
  }

  Future<void> _next() async {
    _history.add(_CompletedRound(
      roundNumber: _roundNumber,
      phrase: _phrase,
      errors: _firstAttemptErrors,
      score: _finalScore ?? 0,
      firstAttempt: _firstAttempt,
      secondAttempt: _secondAttempt,
    ));
    if (_roundNumber >= _roundsPerSession) {
      setState(() => _stage = _Stage.sessionDone);
      return;
    }
    setState(() => _stage = _Stage.starting);
    try {
      await _openRound(_roundNumber + 1);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = 'Не удалось открыть следующий раунд: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Одиночная Игра'),
        actions: [
          if (_stage != _Stage.starting && _stage != _Stage.failed)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: Text(
                  '$_roundNumber / $_roundsPerSession',
                  style: AppFonts.mono(fontSize: 11, weight: FontWeight.w700, color: AppColors.gold),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_stage == _Stage.failed) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bolt, size: 52, color: AppColors.muted),
            const SizedBox(height: 16),
            Text(
              _error ?? 'Что-то пошло не так',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.cream, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => context.canPop() ? context.pop() : context.go('/arena'),
              child: const Text('Назад на Арену'),
            ),
          ],
        ),
      );
    }

    if (_stage == _Stage.starting && _roundId == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        final dock = _dockKey.currentState;
        if (dock != null && dock.hasPendingTake) dock.cancelPending();
      },
      child: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _feedController,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              children: _buildFeed(),
            ),
          ),
          if (_stage == _Stage.sessionDone)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => context.canPop() ? context.pop() : context.go('/arena'),
                  child: const Text('Завершить'),
                ),
              ),
            )
          else if (_stage == _Stage.roundDone)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _next,
                  child: Text(_roundNumber >= _roundsPerSession ? 'Итоги' : 'Следующий раунд'),
                ),
              ),
            )
          else
            VoiceRecorderDock(
              key: _dockKey,
              enabled: _stage == _Stage.awaitingFirst || _stage == _Stage.awaitingSecond,
              onSend: _sendTake,
            ),
        ],
      ),
    );
  }

  /// Техническая панель под попыткой — только пока включён kShowPipelineDebug.
  List<Widget> _debugPanels(String label, RecordingOutcome? attempt) {
    if (!kShowPipelineDebug || attempt == null) return const [];
    return [_PipelineDebug(label: label, outcome: attempt)];
  }

  List<Widget> _buildFeed() {
    final items = <Widget>[];

    for (final done in _history) {
      items.add(_AiSay(roundNumber: done.roundNumber, total: _roundsPerSession, text: done.phrase));
      if (done.errors.isNotEmpty) {
        items.add(_ErrorReport(errors: done.errors, attempt: done.firstAttempt));
      }
      items.add(_ScoreCard(score: done.score, coins: null, attempt: done.secondAttempt));
    }

    if (_stage == _Stage.sessionDone) {
      final avg = _history.isEmpty
          ? 0
          : (_history.map((r) => r.score).reduce((a, b) => a + b) / _history.length).round();
      items.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: ChPanel(
          borderColor: AppColors.gold,
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(
            children: [
              Text('Сессия пройдена', style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800, color: AppColors.gold)),
              const SizedBox(height: 6),
              Text('Средний балл: $avg из 10',
                  style: AppFonts.mono(fontSize: 12, weight: FontWeight.w700, color: AppColors.cream)),
              const SizedBox(height: 4),
              const Text('Рейтинг в этом режиме не меняется',
                  style: TextStyle(color: AppColors.muted, fontSize: 11)),
            ],
          ),
        ),
      ));
      return items;
    }

    items.add(_AiSay(roundNumber: _roundNumber, total: _roundsPerSession, text: _phrase));

    switch (_stage) {
      case _Stage.gradingFirst:
        items.add(const _Thinking(label: 'Разбираю первую попытку'));
        break;
      case _Stage.awaitingSecond:
        items.add(_ErrorReport(errors: _firstAttemptErrors, attempt: _firstAttempt));
        items.addAll(_debugPanels('Попытка 1', _firstAttempt));
        break;
      case _Stage.gradingSecond:
        items.add(_ErrorReport(errors: _firstAttemptErrors, attempt: _firstAttempt));
        items.addAll(_debugPanels('Попытка 1', _firstAttempt));
        items.add(const _Thinking(label: 'Оцениваю вторую попытку'));
        break;
      case _Stage.roundDone:
        items.add(_ErrorReport(errors: _firstAttemptErrors, attempt: _firstAttempt));
        items.addAll(_debugPanels('Попытка 1', _firstAttempt));
        items.add(_ScoreCard(score: _finalScore ?? 0, coins: _earnedCoins, attempt: _secondAttempt));
        items.addAll(_debugPanels('Попытка 2', _secondAttempt));
        break;
      default:
        break;
    }

    return items;
  }
}

class _CompletedRound {
  final int roundNumber;
  final String phrase;
  final List<Map<String, dynamic>> errors;
  final int score;
  final RecordingOutcome? firstAttempt;
  final RecordingOutcome? secondAttempt;

  const _CompletedRound({
    required this.roundNumber,
    required this.phrase,
    required this.errors,
    required this.score,
    required this.firstAttempt,
    required this.secondAttempt,
  });
}

class _AiSay extends StatelessWidget {
  final int roundNumber;
  final int total;
  final String text;

  const _AiSay({required this.roundNumber, required this.total, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CircleAvatar(
            radius: 14,
            backgroundColor: AppColors.gold,
            child: Icon(Icons.smart_toy, size: 16, color: Colors.black),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: AppColors.navy3,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(14),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Раунд $roundNumber из $total', style: AppFonts.mono(fontSize: 9, color: AppColors.muted)),
                  const SizedBox(height: 5),
                  Text(text, style: const TextStyle(color: AppColors.cream, height: 1.4)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  final String label;

  const _Thinking({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        ],
      ),
    );
  }
}

/// Разбор ошибок после первой попытки — то, ради чего в соло есть вторая
/// попытка (раздел 2.2, шаги 3-4).
///
/// Заголовок панели зависит не только от того, нашлись ли ошибки: тишина и
/// сбой распознавания — это НЕ «ошибок не найдено», и раньше все три случая
/// выглядели одинаково, из-за чего сломанное распознавание речи выглядело
/// как безупречный ответ.
class _ErrorReport extends StatelessWidget {
  final List<Map<String, dynamic>> errors;
  final RecordingOutcome? attempt;

  const _ErrorReport({required this.errors, required this.attempt});

  @override
  Widget build(BuildContext context) {
    final status = attempt?.status ?? TranscriptStatus.ok;
    final judge = attempt?.judgeStatus ?? JudgeStatus.ok;
    // Судья не ответил — пустой список ошибок НЕ значит, что ошибок нет.
    final judgeBroken = judge == JudgeStatus.degraded;
    final notRecognised = status == TranscriptStatus.empty || status == TranscriptStatus.failed;

    final (String title, Color titleColor) = switch (status) {
      TranscriptStatus.failed => ('РЕЧЬ НЕ РАСПОЗНАНА', AppColors.muted),
      TranscriptStatus.empty => ('НИЧЕГО НЕ УСЛЫШАЛ', AppColors.muted),
      _ when judgeBroken => ('РАЗБОР НЕ ПОЛУЧЕН', AppColors.muted),
      _ => errors.isEmpty ? ('ОШИБОК НЕ НАЙДЕНО', AppColors.ok) : ('РАЗБОР ПЕРВОЙ ПОПЫТКИ', AppColors.gold),
    };

    final String hint = switch (status) {
      TranscriptStatus.failed =>
        'Не удалось распознать речь — это сбой на нашей стороне, балл за него не снижается. Попробуй сказать фразу ещё раз.',
      TranscriptStatus.empty =>
        'Похоже, записалась тишина. Говори чётче и ближе к микрофону, удерживая кнопку всё время, пока говоришь.',
      _ when judgeBroken =>
        'ИИ-судья не ответил, поэтому разбора ошибок нет — это сбой на нашей стороне, а не признак того, что ошибок не было. Балл за него не снижается.',
      _ => 'Скажи фразу ещё раз — вторая попытка идёт в зачёт.',
    };

    final transcript = attempt?.transcript ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ChPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: titleColor)),
            const SizedBox(height: 8),
            // Игрок должен видеть, что именно услышал распознаватель —
            // иначе разбор ошибок в чужой по сути фразе выглядит абсурдом.
            if (transcript.isNotEmpty) ...[
              Text(
                '«$transcript»',
                style: const TextStyle(
                  color: AppColors.cream,
                  fontSize: 12,
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (errors.isEmpty || notRecognised || judgeBroken)
              Text(hint, style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4))
            else
              ...errors.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (e['message'] as String?) ?? '',
                          style: const TextStyle(color: AppColors.cream, fontSize: 12, height: 1.4),
                        ),
                        if ((e['replacement'] as String?)?.isNotEmpty ?? false)
                          Text(
                            '→ ${e['replacement']}',
                            style: AppFonts.mono(fontSize: 11, weight: FontWeight.w700, color: AppColors.ok),
                          ),
                      ],
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}

class _ScoreCard extends StatelessWidget {
  final int score;
  final int? coins;

  /// Итог распознавания ВТОРОЙ попытки — именно она идёт в зачёт. Нужен,
  /// чтобы объяснить балл, выставленный не за качество речи, а из-за тишины
  /// или сбоя распознавания.
  final RecordingOutcome? attempt;

  const _ScoreCard({required this.score, required this.coins, this.attempt});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ChPanel(
        borderColor: AppColors.gold,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        child: Row(
          children: [
            Container(
              height: 44,
              width: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.navy3,
                border: Border.all(color: AppColors.gold, width: 2.5),
              ),
              child: Center(
                child: Text('$score', style: AppFonts.ui(fontSize: 17, weight: FontWeight.w800, color: AppColors.gold)),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Балл за раунд', style: AppFonts.ui(fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                    coins == null ? 'Рейтинг не меняется' : '+$coins монет · рейтинг не меняется',
                    style: const TextStyle(color: AppColors.muted, fontSize: 11),
                  ),
                  if (attempt?.judgeStatus == JudgeStatus.degraded)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'ИИ-судья не ответил — балл нейтральный, не в минус тебе',
                        style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.3),
                      ),
                    )
                  else if (attempt?.status == TranscriptStatus.failed)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Речь распознать не удалось — балл нейтральный, не в минус тебе',
                        style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.3),
                      ),
                    )
                  else if (attempt?.status == TranscriptStatus.empty)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Во второй попытке записалась тишина',
                        style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.3),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Техническая панель пайплайна — что на самом деле ответили распознавание
/// и судья. Включается константой kShowPipelineDebug.
///
/// Существует потому, что нейтральные 7 баллов при молчащем судье выглядят
/// как настоящая оценка: по экрану невозможно было понять, сломалось ли
/// что-то и что именно. Здесь показывается сырьё, а не пересказ.
class _PipelineDebug extends StatelessWidget {
  final String label;
  final RecordingOutcome outcome;

  const _PipelineDebug({required this.label, required this.outcome});

  @override
  Widget build(BuildContext context) {
    final asr = outcome.asrDebug;
    final judge = outcome.judgeDebug;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ChPanel(
        borderColor: AppColors.muted,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ОТЛАДКА · $label',
              style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            _block(
              'ASR ответил',
              outcome.transcript.isNotEmpty ? '«${outcome.transcript}»' : _asrFallbackText(),
              _meta([
                if (asr?['provider'] != null) '${asr!['provider']}/${asr['model']}',
                if (asr?['language'] != null) '${asr!['language']}',
                if (asr?['audio_seconds'] != null) 'аудио ${asr!['audio_seconds']} с',
                if (asr?['elapsed_ms'] != null) '${asr!['elapsed_ms']} мс',
                if (asr?['confidence'] != null) 'уверенность ${asr!['confidence']}',
                'статус ${outcome.status.name}',
              ]),
              asr?['error']?.toString(),
            ),
            const SizedBox(height: 10),
            _block(
              'LLM ответил',
              _judgeText(judge),
              _meta([
                if (judge?['model'] != null) '${judge!['model']}',
                if (judge?['elapsed_ms'] != null) '${judge!['elapsed_ms']} мс',
                if (judge?['attempts'] != null) 'попыток ${judge!['attempts']}',
                if (judge?['errors_count'] != null) 'ошибок ${judge!['errors_count']}',
                'статус ${outcome.judgeStatus.name}',
              ]),
              judge?['reason']?.toString(),
            ),
          ],
        ),
      ),
    );
  }

  String _asrFallbackText() => switch (outcome.status) {
        TranscriptStatus.empty => '(пусто — речи не услышал)',
        TranscriptStatus.failed => '(сбой распознавания)',
        _ => '(нет данных)',
      };

  /// Для судьи важнее всего СЫРОЙ ответ модели: именно по нему видно,
  /// прислала ли она JSON не той формы, markdown-обёртку или вообще ничего.
  String _judgeText(Map<String, dynamic>? judge) {
    final raw = judge?['raw']?.toString();
    if (raw != null && raw.isNotEmpty) return raw;
    return switch (outcome.judgeStatus) {
      JudgeStatus.skipped => '(не вызывался — ${judge?['reason'] ?? 'нечего разбирать'})',
      JudgeStatus.degraded => '(ответа нет, см. причину ниже)',
      JudgeStatus.pending => '(ещё не отработал)',
      JudgeStatus.ok => '(ответ разобран, сырьё не сохранено)',
    };
  }

  String _meta(List<String> parts) => parts.where((p) => p.isNotEmpty).join(' · ');

  Widget _block(String title, String body, String meta, String? error) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.gold)),
        const SizedBox(height: 3),
        SelectableText(
          body,
          style: const TextStyle(color: AppColors.cream, fontSize: 11, height: 1.35),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(meta, style: AppFonts.mono(fontSize: 9, color: AppColors.muted)),
        ],
        if (error != null && error.isNotEmpty) ...[
          const SizedBox(height: 3),
          SelectableText(
            error,
            style: const TextStyle(color: AppColors.danger, fontSize: 10, height: 1.3),
          ),
        ],
      ],
    );
  }
}
