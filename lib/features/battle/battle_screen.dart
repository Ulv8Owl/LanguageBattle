import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/languages.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/phrase_bank.dart';
import '../../data/voice_submission.dart';
import '../../widgets/voice_message_bubble.dart';
import '../../widgets/voice_recorder_dock.dart';
import 'battle_models.dart';

/// Экран боя — непрерывная лента-переписка (раздел 5.2, задача 4 итерации).
///
/// Раунды не листаются постранично: фраза от ИИ и голосовые обеих сторон
/// накапливаются в одной ленте. Матч длится ровно 10 раундов, а в шапке
/// показывается счёт ВЫИГРАННЫХ РАУНДОВ (кто набрал в раунде больше баллов —
/// тому очко), поэтому сумма двух чисел в шапке доходит до 10 к концу матча.
///
/// В интерфейсе нет текстовых подсказок: состояние записи передаётся только
/// самой кнопкой микрофона (см. VoiceRecorderDock).
///
/// Раунд имеет таймаут (см. deferred_suggestions.md, пункт 5 — реализовано
/// по отдельному запросу): если игрок не отправил голосовое за
/// [_roundTimeoutSeconds] секунд после появления фразы, серверная функция
/// `auto_skip_stale_rounds` засчитывает ему минимальный балл за раунд, чтобы
/// брошенный матч не зависал в `in_progress` навсегда. Обратный отсчёт в
/// шапке — это таймаут именно на "начать отвечать", а не ограничение на
/// длину самого голосового.
///
/// Аудио удаляется из Storage сразу после завершения матча — оно не
/// хранится "про запас" (сознательное решение, отличается от спеки, где
/// экран итогов мог бы предлагать переслушать голосовое; эта возможность
/// сознательно не реализуется).
class BattleScreen extends StatefulWidget {
  final String matchId;

  const BattleScreen({super.key, required this.matchId});

  @override
  State<BattleScreen> createState() => _BattleScreenState();
}

class _BattleScreenState extends State<BattleScreen> {
  final String _myId = currentUserId;
  final _dockKey = GlobalKey<VoiceRecorderDockState>();
  final _feedController = ScrollController();

  MatchData? _match;
  String _opponentName = '…';
  String _myName = 'Ты';

  /// Родной язык игрока — на нём показывается фраза раунда. Говорить нужно
  /// на изучаемом: задание в том, чтобы ПЕРЕВЕСТИ фразу вслух, а не
  /// прочитать готовый текст.
  String _myNativeLanguage = 'ru';
  List<RoundData> _rounds = [];
  List<VoiceRecordingData> _recordings = [];
  List<RoundScoreData> _scores = [];
  bool _loading = true;
  bool _navigatedAway = false;
  String? _actionError;

  StreamSubscription? _matchSub;
  StreamSubscription? _roundsSub;
  StreamSubscription? _recordingsSub;
  StreamSubscription? _scoresSub;

  /// Сколько секунд даётся игроку на то, чтобы НАЧАТЬ отвечать в раунде
  /// (не на длину самой записи) — раздел 7 спеки называет диапазон 30-45с.
  static const _roundTimeoutSeconds = 40;

  /// Раз в секунду будит build(), чтобы обратный отсчёт в шапке был живым.
  Timer? _tickTimer;

  /// Раз в несколько секунд просит сервер списать штраф за брошенный раунд
  /// (см. auto_skip_stale_rounds в 0007_round_timeout_and_cleanup.sql).
  /// Идемпотентно — повторные вызовы безвредны.
  Timer? _sweepTimer;

  @override
  void initState() {
    super.initState();
    _init();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _sweepTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      supabase.rpc('auto_skip_stale_rounds').catchError((_) => null);
    });
  }

  Future<void> _init() async {
    try {
      final row = await supabase.from('matches').select().eq('id', widget.matchId).single();
      _match = MatchData.fromRow(row);
      final opponentId = _match!.playerAId == _myId ? _match!.playerBId : _match!.playerAId;
      if (opponentId != null) {
        final opp = await supabase.from('users').select('username').eq('id', opponentId).maybeSingle();
        _opponentName = (opp?['username'] as String?) ?? 'Соперник';
      }
      final me = await supabase
          .from('users')
          .select('username, native_language')
          .eq('id', _myId)
          .maybeSingle();
      _myName = (me?['username'] as String?) ?? 'Ты';
      _myNativeLanguage = (me?['native_language'] as String?) ?? 'ru';
    } catch (e) {
      _actionError = 'Не удалось загрузить матч: $e';
    }
    if (!mounted) return;
    setState(() => _loading = false);

    _matchSub = supabase
        .from('matches')
        .stream(primaryKey: ['id'])
        .eq('id', widget.matchId)
        .listen((rows) {
      if (!mounted || rows.isEmpty) return;
      setState(() => _match = MatchData.fromRow(rows.first));
      if (_match!.status == 'completed' && !_navigatedAway) {
        _navigatedAway = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.go('/battle/${widget.matchId}/results');
        });
      }
    });

    _roundsSub = supabase
        .from('rounds')
        .stream(primaryKey: ['id'])
        .eq('match_id', widget.matchId)
        .order('round_number')
        .listen((rows) {
      if (!mounted) return;
      setState(() => _rounds = rows.map(RoundData.fromRow).toList());
      _scrollToBottomSoon();
      _maybeAdvance();
    });

    // Not filtered by this match's round ids here — the rounds stream and
    // this stream are independent Realtime subscriptions with no ordering
    // guarantee between them, so a recording/score could otherwise arrive
    // "before" its round locally. Filtering happens at render/lookup time
    // instead (RLS still limits rows to matches the user participates in).
    _recordingsSub = supabase.from('voice_recordings').stream(primaryKey: ['id']).listen((rows) {
      if (!mounted) return;
      setState(() {
        _recordings = rows.where((r) => r['round_id'] != null).map(VoiceRecordingData.fromRow).toList();
      });
      _scrollToBottomSoon();
      _maybeAdvance();
    });

    _scoresSub = supabase.from('round_scores').stream(primaryKey: ['id']).listen((rows) {
      if (!mounted) return;
      setState(() => _scores = rows.map(RoundScoreData.fromRow).toList());
      _maybeAdvance();
    });
  }

  @override
  void dispose() {
    _matchSub?.cancel();
    _roundsSub?.cancel();
    _recordingsSub?.cancel();
    _scoresSub?.cancel();
    _tickTimer?.cancel();
    _sweepTimer?.cancel();
    _feedController.dispose();
    super.dispose();
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

  // ---------------------------------------------------------------------
  // Round progression (client-driven, dedup'd via DB constraints)
  // ---------------------------------------------------------------------

  VoiceRecordingData? _recordingFor(String roundId, String userId, String slot) {
    for (final r in _recordings) {
      if (r.roundId == roundId && r.userId == userId && r.recordingSlot == slot) return r;
    }
    return null;
  }

  int? _scoreFor(String roundId, String? userId) {
    if (userId == null) return null;
    for (final s in _scores) {
      if (s.roundId == roundId && s.userId == userId) return s.score;
    }
    return null;
  }

  bool _roundFullyScored(RoundData r) {
    final m = _match!;
    return _scoreFor(r.id, m.playerAId) != null && _scoreFor(r.id, m.playerBId) != null;
  }

  /// Секунд до автосписания раунда, null — если считать нечего (матч не
  /// идёт, раундов ещё нет, или последний раунд уже полностью оценён).
  int? get _roundSecondsLeft {
    final m = _match;
    final round = _lastRound;
    if (m == null || round == null || m.status != 'in_progress') return null;
    if (_roundFullyScored(round)) return null;
    final elapsed = DateTime.now().toUtc().difference(round.createdAt.toUtc()).inSeconds;
    final left = _roundTimeoutSeconds - elapsed;
    return left > 0 ? left : 0;
  }

  Future<void> _maybeAdvance() async {
    final m = _match;
    if (m == null || m.status != 'in_progress') return;
    if (_rounds.isEmpty) {
      await _tryCreateRound(1);
      return;
    }
    final last = _lastRound!;
    if (!_roundFullyScored(last)) return;
    if (last.roundNumber >= 10) {
      await _tryCompleteMatch();
    } else if (!_rounds.any((r) => r.roundNumber == last.roundNumber + 1)) {
      await _tryCreateRound(last.roundNumber + 1);
    }
  }

  Future<void> _tryCreateRound(int n) async {
    final m = _match!;
    // Рандом по фиксированному банку фраз (не генерация LLM — см.
    // lib/data/phrase_bank.dart), без повторов уже сыгранных в этом матче.
    final usedIndices = _rounds.map((r) => r.phraseIndex).whereType<int>().toSet();
    final phraseIndex = PhraseBank.randomIndex(exclude: usedIndices);
    final phrase = m.isDuel
        ? '${PhraseBank.textFor(phraseIndex, m.languageForSlot(m.playerAId!, 'target'))} / '
            '${PhraseBank.textFor(phraseIndex, m.languageForSlot(m.playerBId!, 'target'))}'
        : PhraseBank.textFor(phraseIndex, m.languagePair ?? 'en');
    try {
      await supabase.from('rounds').upsert(
        {
          'match_id': m.id,
          'round_number': n,
          'generated_phrase': phrase,
          'phrase_index': phraseIndex,
        },
        onConflict: 'match_id,round_number',
        ignoreDuplicates: true,
      );
    } catch (_) {
      // Lost the race to the other client's identical insert — fine, their
      // row will arrive over Realtime.
    }
  }

  Future<void> _tryCompleteMatch() async {
    final m = _match!;
    try {
      // finalize_match — security definer RPC (победитель по выигранным
      // раундам, пересчёт ELO, начисление валюты/опыта): клиент не может
      // писать напрямую в currency_wallets и users.xp, и сам результат
      // матча пересчитывается на сервере из round_scores.
      final result = await supabase.rpc('finalize_match', params: {'p_match_id': m.id});
      final alreadyCompleted = result is Map && result['already_completed'] == true;
      if (!alreadyCompleted) {
        // Аудио этого матча больше не нужно — держать его "про запас" не
        // просили, наоборот, попросили удалять сразу после боя. Делает это
        // только тот клиент, чей вызов finalize_match реально сработал
        // первым, чтобы не гонять Storage API дважды на один и тот же матч.
        await _deleteMatchRecordings();
      }
    } catch (_) {
      // Другой клиент уже финализировал матч (или ещё не все раунды
      // синхронизировались локально) — статус придёт через Realtime.
    }
  }

  /// Удаляет из Storage все голосовые именно ЭТОГО матча. `_recordings`
  /// в состоянии экрана — общий, не отфильтрованный по матчу поток (см.
  /// комментарий у `_recordingsSub`), поэтому фильтруем по id раундов
  /// текущего матча, а не берём список как есть.
  Future<void> _deleteMatchRecordings() async {
    final roundIds = _rounds.map((r) => r.id).toSet();
    final paths = _recordings
        .where((r) => roundIds.contains(r.roundId))
        .map((r) => r.audioStoragePath)
        .toList();
    if (paths.isEmpty) return;
    try {
      await supabase.storage.from('voice-recordings').remove(paths);
    } catch (e) {
      debugPrint('failed to delete match recordings: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Recording flow
  // ---------------------------------------------------------------------

  RoundData? get _lastRound {
    if (_rounds.isEmpty) return null;
    RoundData last = _rounds.first;
    for (final r in _rounds) {
      if (r.roundNumber > last.roundNumber) last = r;
    }
    return last;
  }

  /// Слот, который игроку ещё предстоит записать в текущем раунде.
  /// В Дуэли это сначала 'native', затем 'target'; в Состязании только
  /// 'target'. null — всё записано, ждём соперника.
  String? get _nextSlot {
    final round = _lastRound;
    final m = _match;
    if (round == null || m == null) return null;
    for (final slot in m.requiredSlots) {
      if (_recordingFor(round.id, _myId, slot) == null) return slot;
    }
    return null;
  }

  Future<void> _sendTake(VoiceTake take) async {
    final round = _lastRound;
    final slot = _nextSlot;
    final m = _match;
    if (round == null || slot == null || m == null) return;

    try {
      // Загрузка, строка в voice_recordings и задача в очередь оценки —
      // общий с Одиночной Игрой путь (lib/data/voice_submission.dart).
      // Клиент дальше НЕ ждёт результат синхронно, он придёт через Realtime
      // на round_scores.
      await submitVoiceRecording(
        filePath: take.filePath,
        storagePath: battleRecordingPath(
          matchId: m.id,
          roundId: round.id,
          userId: _myId,
          slot: slot,
        ),
        userId: _myId,
        languageCode: m.languageForSlot(_myId, slot),
        recordingSlot: slot,
        durationSeconds: take.durationSeconds,
        roundId: round.id,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось отправить голосовое: $e')),
        );
      }
      rethrow;
    }
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final m = _match;
    if (m == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Бой')),
        body: Center(child: Text(_actionError ?? 'Матч не найден')),
      );
    }

    final opponentId = m.playerAId == _myId ? m.playerBId : m.playerAId;
    var myWins = 0;
    var opponentWins = 0;
    for (final r in _rounds) {
      final mine = _scoreFor(r.id, _myId);
      final theirs = _scoreFor(r.id, opponentId);
      if (mine == null || theirs == null) continue;
      if (mine > theirs) {
        myWins++;
      } else if (theirs > mine) {
        opponentWins++;
      }
    }

    final slot = _nextSlot;
    final canRecord = slot != null && m.status == 'in_progress';

    return Scaffold(
      appBar: AppBar(title: Text(m.isDuel ? 'Дуэль' : 'Состязание')),
      // Тап мимо кнопки микрофона сбрасывает подготовленное голосовое
      // (раздел 5.2) — можно перезаписать заново.
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          final dock = _dockKey.currentState;
          if (dock != null && dock.hasPendingTake) dock.cancelPending();
        },
        child: SafeArea(
          child: Column(
            children: [
              _ScoreHeader(
                myWins: myWins,
                opponentWins: opponentWins,
                myName: _myName,
                opponentName: _opponentName,
                secondsLeft: _roundSecondsLeft,
              ),
              Expanded(
                child: _rounds.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        controller: _feedController,
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        children: _buildFeed(m, opponentId),
                      ),
              ),
              VoiceRecorderDock(
                key: _dockKey,
                enabled: canRecord,
                onSend: _sendTake,
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildFeed(MatchData m, String? opponentId) {
    final items = <Widget>[];
    for (final round in _rounds) {
      // Показываем фразу на РОДНОМ языке игрока: он должен перевести её
      // вслух на изучаемый. В generated_phrase лежит вариант на изучаемом
      // языке — это то, что игрок должен произнести, и оно идёт подсказкой
      // распознавателю речи, поэтому на экран не годится.
      final promptText = round.phraseIndex != null
          ? PhraseBank.textFor(round.phraseIndex!, _myNativeLanguage)
          : (round.generatedPhrase ?? '…');
      // Подпись «на каком языке отвечать» — только у текущего раунда: в
      // Дуэли слоты идут по очереди (сначала родной, потом изучаемый), и
      // для уже сыгранных раундов правильного ответа на этот вопрос нет.
      final isCurrent = round.id == _lastRound?.id;
      final slot = _nextSlot;
      items.add(_AiBubble(
        roundNumber: round.roundNumber,
        text: promptText,
        targetLanguage: isCurrent && slot != null ? m.languageForSlot(_myId, slot) : null,
      ));
      for (final slot in m.requiredSlots) {
        final mine = _recordingFor(round.id, _myId, slot);
        final theirs = opponentId == null ? null : _recordingFor(round.id, opponentId, slot);
        // Балл ставится только за голосовое на изучаемом языке — родное
        // в Дуэли соперник просто слушает (раздел 2.4).
        final myScore = slot == 'target' ? _scoreFor(round.id, _myId) : null;
        final theirScore = slot == 'target' ? _scoreFor(round.id, opponentId) : null;
        if (mine != null) {
          items.add(VoiceMessageBubble(
            key: ValueKey('${mine.id}-mine'),
            audioStoragePath: mine.audioStoragePath,
            name: _myName,
            alignRight: false,
            score: myScore,
            scorePending: slot == 'target',
          ));
        }
        if (theirs != null) {
          items.add(VoiceMessageBubble(
            key: ValueKey('${theirs.id}-theirs'),
            audioStoragePath: theirs.audioStoragePath,
            name: _opponentName,
            alignRight: true,
            score: theirScore,
            scorePending: slot == 'target',
          ));
        }
      }
    }
    return items;
  }
}

/// Шапка: живой счёт ВЫИГРАННЫХ РАУНДОВ, между кружками — разделитель, под
/// ними — обратный отсчёт до автосписания раунда (задача 5 итерации).
class _ScoreHeader extends StatelessWidget {
  final int myWins;
  final int opponentWins;
  final String myName;
  final String opponentName;
  final int? secondsLeft;

  const _ScoreHeader({
    required this.myWins,
    required this.opponentWins,
    required this.myName,
    required this.opponentName,
    required this.secondsLeft,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ScoreCircle(value: myWins, color: AppColors.gold, name: myName),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('/', style: TextStyle(fontSize: 20, color: AppColors.muted, fontWeight: FontWeight.w700)),
              ),
              _ScoreCircle(value: opponentWins, color: AppColors.cyan, name: opponentName),
            ],
          ),
          if (secondsLeft != null) ...[
            const SizedBox(height: 8),
            _RoundCountdown(seconds: secondsLeft!),
          ],
        ],
      ),
    );
  }
}

class _RoundCountdown extends StatelessWidget {
  final int seconds;

  const _RoundCountdown({required this.seconds});

  @override
  Widget build(BuildContext context) {
    final urgent = seconds <= 10;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.navy3,
        border: Border.all(color: urgent ? AppColors.danger : AppColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 12, color: urgent ? AppColors.danger : AppColors.muted),
          const SizedBox(width: 4),
          Text(
            '$secondsс',
            style: AppFonts.mono(
              fontSize: 10,
              weight: FontWeight.w700,
              color: urgent ? AppColors.danger : AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreCircle extends StatelessWidget {
  final int value;
  final Color color;
  final String name;

  const _ScoreCircle({required this.value, required this.color, required this.name});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 46,
          width: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.navy3,
            border: Border.all(color: color, width: 2.5),
            boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 12)],
          ),
          child: Center(
            child: Text('$value', style: AppFonts.ui(fontSize: 18, weight: FontWeight.w800, color: color)),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 78,
          child: Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.mono(fontSize: 9, color: AppColors.muted),
          ),
        ),
      ],
    );
  }
}

/// Фраза от ИИ — входящее сообщение с иконкой.
class _AiBubble extends StatelessWidget {
  final int roundNumber;
  final String text;

  /// Язык, на котором нужно ОТВЕТИТЬ. Текст показан на родном языке
  /// игрока — без подписи непонятно, повторить его или перевести.
  /// null — для уже сыгранных раундов: там подсказывать нечего.
  final String? targetLanguage;

  const _AiBubble({required this.roundNumber, required this.text, required this.targetLanguage});

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
                  Text('Раунд $roundNumber из 10', style: AppFonts.mono(fontSize: 9, color: AppColors.muted)),
                  const SizedBox(height: 5),
                  Text(text, style: const TextStyle(color: AppColors.cream, height: 1.4)),
                  if (targetLanguage != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      speakInLabel(targetLanguage!),
                      style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Голосовое в ленте: своё — слева с аватаром и волной, соперника — справа
/// зеркально. Балл за раунд прикрепляется к сообщению сразу после оценки.
