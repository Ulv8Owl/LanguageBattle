import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../../core/game_access.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/phrase_bank.dart';
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
  int? _finalScore;
  int? _earnedCoins;

  /// История пройденных раундов сессии — рисуется той же лентой.
  final List<_CompletedRound> _history = [];

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
    final phrase = PhraseBank.pick(_targetLanguage, n);
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
      final storagePath = 'training/$sessionId/$roundId/${_myId}_$attempt.m4a';
      await supabase.storage.from('voice-recordings').upload(
            storagePath,
            File(take.filePath),
            fileOptions: const FileOptions(upsert: true, contentType: 'audio/m4a'),
          );
      final words = take.transcript.isEmpty ? const <String>[] : take.transcript.split(RegExp(r'\s+'));
      final inserted = await supabase
          .from('voice_recordings')
          .insert({
            'training_round_id': roundId,
            'user_id': _myId,
            'recording_slot': 'target',
            'language_code': _targetLanguage,
            'audio_storage_path': storagePath,
            'duration_seconds': take.durationSeconds,
            'transcript': take.transcript,
            'word_confidences': words.map((w) => {'word': w, 'confidence': take.confidence}).toList(),
          })
          .select()
          .single();
      final recordingId = inserted['id'] as String;
      await supabase.from('evaluation_jobs').insert({
        'voice_recording_id': recordingId,
        'status': 'pending',
      });

      if (!mounted) return;
      setState(() => _stage = attempt == 1 ? _Stage.gradingFirst : _Stage.gradingSecond);
      _scrollToBottomSoon();

      if (attempt == 1) {
        _watchFirstAttempt(recordingId);
      } else {
        _watchFinalScore(roundId);
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
    _jobSub = supabase
        .from('evaluation_jobs')
        .stream(primaryKey: ['id'])
        .eq('voice_recording_id', recordingId)
        .listen((rows) async {
      if (!mounted || rows.isEmpty) return;
      final status = rows.first['status'] as String?;
      if (status != 'done' && status != 'failed') return;
      _jobSub?.cancel();

      final errors = await supabase
          .from('grammar_errors')
          .select()
          .eq('voice_recording_id', recordingId)
          .order('offset_start');
      if (!mounted) return;
      setState(() {
        _firstAttemptErrors = List<Map<String, dynamic>>.from(errors);
        _stage = _Stage.awaitingSecond;
      });
      _scrollToBottomSoon();
    });
  }

  /// Финальный балл за раунд пишет воркер в training_rounds.final_score.
  void _watchFinalScore(String roundId) {
    _roundSub?.cancel();
    _roundSub = supabase
        .from('training_rounds')
        .stream(primaryKey: ['id'])
        .eq('id', roundId)
        .listen((rows) async {
      if (!mounted || rows.isEmpty) return;
      final score = rows.first['final_score'] as int?;
      if (score == null) return;
      _roundSub?.cancel();

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

      if (!mounted) return;
      setState(() {
        _finalScore = score;
        _earnedCoins = coins;
        _stage = _Stage.roundDone;
      });
      _scrollToBottomSoon();
    });
  }

  Future<void> _next() async {
    _history.add(_CompletedRound(
      roundNumber: _roundNumber,
      phrase: _phrase,
      errors: _firstAttemptErrors,
      score: _finalScore ?? 0,
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
              languageCode: _targetLanguage,
              onSend: _sendTake,
            ),
        ],
      ),
    );
  }

  List<Widget> _buildFeed() {
    final items = <Widget>[];

    for (final done in _history) {
      items.add(_AiSay(roundNumber: done.roundNumber, total: _roundsPerSession, text: done.phrase));
      if (done.errors.isNotEmpty) items.add(_ErrorReport(errors: done.errors));
      items.add(_ScoreCard(score: done.score, coins: null));
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
        items.add(_ErrorReport(errors: _firstAttemptErrors));
        break;
      case _Stage.gradingSecond:
        items.add(_ErrorReport(errors: _firstAttemptErrors));
        items.add(const _Thinking(label: 'Оцениваю вторую попытку'));
        break;
      case _Stage.roundDone:
        items.add(_ErrorReport(errors: _firstAttemptErrors));
        items.add(_ScoreCard(score: _finalScore ?? 0, coins: _earnedCoins));
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

  const _CompletedRound({
    required this.roundNumber,
    required this.phrase,
    required this.errors,
    required this.score,
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
class _ErrorReport extends StatelessWidget {
  final List<Map<String, dynamic>> errors;

  const _ErrorReport({required this.errors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ChPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              errors.isEmpty ? 'ОШИБОК НЕ НАЙДЕНО' : 'РАЗБОР ПЕРВОЙ ПОПЫТКИ',
              style: AppFonts.mono(
                fontSize: 9,
                weight: FontWeight.w700,
                color: errors.isEmpty ? AppColors.ok : AppColors.gold,
              ),
            ),
            const SizedBox(height: 8),
            if (errors.isEmpty)
              const Text(
                'Скажи фразу ещё раз — вторая попытка идёт в зачёт.',
                style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
              )
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

  const _ScoreCard({required this.score, required this.coins});

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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
