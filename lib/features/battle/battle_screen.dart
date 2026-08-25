import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import 'package:uuid/uuid.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/phrase_bank.dart';
import 'battle_models.dart';

enum _MicState { idle, recording, ready }

/// Локали on-device распознавания речи (раздел 9.1 — ASR временно через
/// встроенный движок Android/iOS вместо облачного адаптера; заменяется
/// позже без изменений в остальном пайплайне, см. supabase/README.md).
const _speechLocaleByLanguage = {
  'en': 'en_US',
  'es': 'es_ES',
  'ru': 'ru_RU',
};

/// Боевой экран: полный цикл записи/загрузки/прослушки голосовых и
/// продвижения раундов через Realtime. Транскрипт снимается on-device во
/// время записи; реальную грамматическую оценку считает Edge Function
/// evaluate-recording (DeepSeek), запускаемая триггером на evaluation_jobs.
class BattleScreen extends StatefulWidget {
  final String matchId;

  const BattleScreen({super.key, required this.matchId});

  @override
  State<BattleScreen> createState() => _BattleScreenState();
}

class _BattleScreenState extends State<BattleScreen> with SingleTickerProviderStateMixin {
  final String _myId = currentUserId;

  MatchData? _match;
  String _opponentName = '…';
  List<RoundData> _rounds = [];
  List<VoiceRecordingData> _recordings = [];
  List<RoundScoreData> _scores = [];
  bool _loading = true;
  bool _navigatedAway = false;

  StreamSubscription? _matchSub;
  StreamSubscription? _roundsSub;
  StreamSubscription? _recordingsSub;
  StreamSubscription? _scoresSub;

  final _recorder = AudioRecorder();
  final _speech = SpeechToText();
  bool _speechAvailable = false;
  String _liveTranscript = '';
  double _liveConfidence = 1.0;
  _MicState _micState = _MicState.idle;
  String? _pendingFilePath;
  Stopwatch? _recordStopwatch;
  bool _uploading = false;
  String? _actionError;

  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _speechAvailable = await _speech.initialize(
        onError: (e) => debugPrint('speech_to_text error: $e'),
      );
    } catch (e) {
      debugPrint('speech_to_text init failed: $e');
    }
    try {
      final row = await supabase.from('matches').select().eq('id', widget.matchId).single();
      _match = MatchData.fromRow(row);
      final opponentId = _match!.playerAId == _myId ? _match!.playerBId : _match!.playerAId;
      if (opponentId != null) {
        final opp = await supabase
            .from('users')
            .select('username')
            .eq('id', opponentId)
            .maybeSingle();
        _opponentName = (opp?['username'] as String?) ?? 'Соперник';
      }
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
        _recordings = rows
            .where((r) => r['round_id'] != null)
            .map(VoiceRecordingData.fromRow)
            .toList();
      });
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
    _pulseController.dispose();
    _recorder.dispose();
    _speech.cancel();
    super.dispose();
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

  Future<void> _maybeAdvance() async {
    final m = _match;
    if (m == null || m.status != 'in_progress') return;
    if (_rounds.isEmpty) {
      await _tryCreateRound(1);
      return;
    }
    RoundData last = _rounds.first;
    for (final r in _rounds) {
      if (r.roundNumber > last.roundNumber) last = r;
    }
    if (!_roundFullyScored(last)) return;
    if (last.roundNumber >= 10) {
      await _tryCompleteMatch();
    } else if (!_rounds.any((r) => r.roundNumber == last.roundNumber + 1)) {
      await _tryCreateRound(last.roundNumber + 1);
    }
  }

  Future<void> _tryCreateRound(int n) async {
    final m = _match!;
    final phrase = m.isDuel
        ? '${PhraseBank.pick(m.languageForSlot(m.playerAId!, 'target'), n)} / '
            '${PhraseBank.pick(m.languageForSlot(m.playerBId!, 'target'), n)}'
        : PhraseBank.pick(m.languagePair ?? 'en', n);
    try {
      await supabase.from('rounds').upsert(
        {
          'match_id': m.id,
          'round_number': n,
          'generated_phrase': phrase,
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
      // finalize_match — security definer RPC (пересчёт ELO, начисление
      // валюты/опыта): клиент не может писать напрямую в currency_wallets
      // и users.xp, и сам результат матча пересчитывается на сервере из
      // round_scores, а не доверяется клиенту.
      await supabase.rpc('finalize_match', params: {'p_match_id': m.id});
    } catch (_) {
      // Другой клиент уже финализировал матч (или ещё не все раунды
      // синхронизировались локально) — статус придёт через Realtime.
    }
  }

  // ---------------------------------------------------------------------
  // Recording flow
  // ---------------------------------------------------------------------

  RoundData? get _currentRound {
    if (_rounds.isEmpty) return null;
    RoundData last = _rounds.first;
    for (final r in _rounds) {
      if (r.roundNumber > last.roundNumber) last = r;
    }
    return last;
  }

  String? get _nextSlot {
    final round = _currentRound;
    final m = _match;
    if (round == null || m == null) return null;
    for (final slot in m.requiredSlots) {
      if (_recordingFor(round.id, _myId, slot) == null) return slot;
    }
    return null;
  }

  Future<void> _startRecording() async {
    final slot = _nextSlot;
    if (slot == null || _micState != _MicState.idle || _uploading) return;
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нет доступа к микрофону')),
        );
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${const Uuid().v4()}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);

    _liveTranscript = '';
    _liveConfidence = 1.0;
    if (_speechAvailable) {
      final language = _match!.languageForSlot(_myId, slot);
      final localeId = _speechLocaleByLanguage[language] ?? 'en_US';
      // Распознавание речи идёт параллельно с записью аудиофайла — так
      // транскрипт готов сразу же, без отдельного шага облачного ASR
      // (раздел 9.1). На части устройств одновременный доступ к микрофону
      // из record + speech_to_text может не сработать — в этом случае
      // просто не будет транскрипта, и оценка мягко деградирует
      // (см. evaluate-recording: пустой транскрипт -> низкий балл, а не
      // падение).
      unawaited(_speech.listen(
        onResult: (result) {
          _liveTranscript = result.recognizedWords;
          if (result.confidence > 0) _liveConfidence = result.confidence;
        },
        listenOptions: SpeechListenOptions(
          localeId: localeId,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
      ));
    }

    if (!mounted) return;
    setState(() {
      _micState = _MicState.recording;
      _pendingFilePath = path;
      _recordStopwatch = Stopwatch()..start();
    });
  }

  Future<void> _stopRecording() async {
    if (_micState != _MicState.recording) return;
    final path = await _recorder.stop();
    if (_speechAvailable) await _speech.stop();
    _recordStopwatch?.stop();
    if (!mounted) return;
    setState(() {
      _micState = _MicState.ready;
      if (path != null) _pendingFilePath = path;
    });
  }

  void _cancelPendingRecording() {
    final path = _pendingFilePath;
    if (path != null) {
      File(path).delete().catchError((_) => File(path));
    }
    setState(() {
      _micState = _MicState.idle;
      _pendingFilePath = null;
      _recordStopwatch = null;
    });
  }

  Future<void> _sendPendingRecording() async {
    final path = _pendingFilePath;
    final round = _currentRound;
    final slot = _nextSlot;
    final m = _match;
    if (path == null || round == null || slot == null || m == null) return;

    setState(() => _uploading = true);
    try {
      final language = m.languageForSlot(_myId, slot);
      final storagePath = 'match/${m.id}/${round.id}/${_myId}_$slot.m4a';
      await supabase.storage.from('voice-recordings').upload(
            storagePath,
            File(path),
            fileOptions: const FileOptions(upsert: true, contentType: 'audio/m4a'),
          );
      final durationSeconds = (_recordStopwatch?.elapsedMilliseconds ?? 0) / 1000.0;
      final transcript = _liveTranscript.trim();
      final words = transcript.isEmpty ? const <String>[] : transcript.split(RegExp(r'\s+'));
      // Встроенный движок распознавания даёт только общую уверенность на всю
      // фразу, а не по каждому слову — присваиваем её всем словам одинаково.
      // Заменится на настоящий per-word confidence вместе с переходом на
      // полноценный ASR-адаптер (раздел 9.7/9.9).
      final wordConfidences = words
          .map((w) => {'word': w, 'confidence': _liveConfidence})
          .toList();
      final inserted = await supabase
          .from('voice_recordings')
          .insert({
            'round_id': round.id,
            'user_id': _myId,
            'recording_slot': slot,
            'language_code': language,
            'audio_storage_path': storagePath,
            'duration_seconds': durationSeconds,
            'transcript': transcript,
            'word_confidences': wordConfidences,
          })
          .select()
          .single();
      await supabase.from('evaluation_jobs').insert({
        'voice_recording_id': inserted['id'],
        'status': 'pending',
      });
      if (!mounted) return;
      setState(() {
        _micState = _MicState.idle;
        _pendingFilePath = null;
        _recordStopwatch = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось отправить голосовое: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
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

    var myTotal = 0;
    var opponentTotal = 0;
    final opponentId = m.playerAId == _myId ? m.playerBId : m.playerAId;
    for (final r in _rounds) {
      myTotal += _scoreFor(r.id, _myId) ?? 0;
      opponentTotal += _scoreFor(r.id, opponentId) ?? 0;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(m.isDuel ? 'Дуэль · $_opponentName' : 'Состязание · $_opponentName'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ScoreHeader(myTotal: myTotal, opponentTotal: opponentTotal, myName: 'Ты', opponentName: _opponentName),
            Expanded(
              child: _rounds.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: _buildFeed(m, opponentId),
                    ),
            ),
            _buildMicBar(),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildFeed(MatchData m, String? opponentId) {
    final items = <Widget>[];
    for (final round in _rounds) {
      items.add(_AiBubble(roundNumber: round.roundNumber, text: round.generatedPhrase ?? '…'));
      for (final slot in m.requiredSlots) {
        final mine = _recordingFor(round.id, _myId, slot);
        final theirs = opponentId == null ? null : _recordingFor(round.id, opponentId, slot);
        if (mine == null && theirs == null) continue;
        final myScore = slot == 'target' ? _scoreFor(round.id, _myId) : null;
        final theirScore = slot == 'target' ? _scoreFor(round.id, opponentId) : null;
        items.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: mine != null
                    ? _RecordingBubble(recording: mine, alignRight: false, score: myScore)
                    : const _PendingBubble(alignRight: false),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: theirs != null
                    ? _RecordingBubble(recording: theirs, alignRight: true, score: theirScore)
                    : const _PendingBubble(alignRight: true),
              ),
            ],
          ),
        ));
      }
    }
    return items;
  }

  Widget _buildMicBar() {
    final round = _currentRound;
    final slot = _nextSlot;
    final m = _match!;
    final waitingForOpponent = round != null && slot == null;

    String? prompt;
    if (round != null && slot != null) {
      prompt = PhraseBank.pick(m.languageForSlot(_myId, slot), round.roundNumber);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        color: AppColors.navy2,
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (waitingForOpponent)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text('Ждём соперника…', style: TextStyle(color: AppColors.muted)),
            )
          else if (prompt != null && _micState == _MicState.idle)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Скажи: "$prompt"',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.cream, fontWeight: FontWeight.w600),
              ),
            ),
          if (_micState == _MicState.ready) _buildReadyPreview(),
          const SizedBox(height: 6),
          _buildMicButton(enabled: !waitingForOpponent && !_uploading),
        ],
      ),
    );
  }

  Widget _buildReadyPreview() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed: () async {
            final path = _pendingFilePath;
            if (path == null) return;
            final player = AudioPlayer();
            await player.play(DeviceFileSource(path));
          },
          icon: const Icon(Icons.play_arrow, color: AppColors.gold),
        ),
        const Text('Голосовое готово', style: TextStyle(color: AppColors.cream)),
        IconButton(
          onPressed: _cancelPendingRecording,
          icon: const Icon(Icons.delete_outline, color: AppColors.danger),
        ),
      ],
    );
  }

  Widget _buildMicButton({required bool enabled}) {
    final disabled = !enabled || _nextSlot == null;
    Widget circle;
    switch (_micState) {
      case _MicState.idle:
        circle = _MicCircle(
          color: disabled ? Colors.white24 : Colors.white,
          icon: Icons.mic,
          iconColor: Colors.black,
        );
        break;
      case _MicState.recording:
        circle = AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            final glow = 8 + _pulseController.value * 10;
            return Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: AppColors.gold.withValues(alpha: 0.6), blurRadius: glow, spreadRadius: 1),
                ],
              ),
              child: child,
            );
          },
          child: const _MicCircle(color: AppColors.gold, icon: Icons.mic, iconColor: Colors.black),
        );
        break;
      case _MicState.ready:
        circle = _uploading
            ? const _MicCircle(
                color: AppColors.gold,
                icon: null,
                iconColor: Colors.black,
                child: SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                ),
              )
            : const _MicCircle(color: AppColors.gold, icon: Icons.send, iconColor: Colors.black);
        break;
    }

    return GestureDetector(
      onLongPressStart: disabled ? null : (_) => _startRecording(),
      onLongPressEnd: disabled ? null : (_) => _stopRecording(),
      onTap: (_micState == _MicState.ready && !_uploading) ? _sendPendingRecording : null,
      child: circle,
    );
  }
}

class _MicCircle extends StatelessWidget {
  final Color color;
  final IconData? icon;
  final Color iconColor;
  final Widget? child;

  const _MicCircle({required this.color, required this.icon, required this.iconColor, this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      width: 64,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Center(child: child ?? Icon(icon, color: iconColor, size: 28)),
    );
  }
}

class _ScoreHeader extends StatelessWidget {
  final int myTotal;
  final int opponentTotal;
  final String myName;
  final String opponentName;

  const _ScoreHeader({
    required this.myTotal,
    required this.opponentTotal,
    required this.myName,
    required this.opponentName,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ScoreCircle(value: myTotal, color: AppColors.gold, name: myName),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('/', style: TextStyle(fontSize: 20, color: AppColors.muted, fontWeight: FontWeight.w700)),
          ),
          _ScoreCircle(value: opponentTotal, color: AppColors.cyan, name: opponentName),
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
        Text(name, style: AppFonts.mono(fontSize: 9, color: AppColors.muted)),
      ],
    );
  }
}

class _AiBubble extends StatelessWidget {
  final int roundNumber;
  final String text;

  const _AiBubble({required this.roundNumber, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CircleAvatar(radius: 14, backgroundColor: AppColors.gold, child: Icon(Icons.smart_toy, size: 16, color: Colors.black)),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.navy3,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Раунд $roundNumber', style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                  const SizedBox(height: 4),
                  Text(text, style: const TextStyle(color: AppColors.cream)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingBubble extends StatelessWidget {
  final bool alignRight;

  const _PendingBubble({required this.alignRight});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text('…', style: TextStyle(color: AppColors.muted)),
      ),
    );
  }
}

class _RecordingBubble extends StatefulWidget {
  final VoiceRecordingData recording;
  final bool alignRight;
  final int? score;

  const _RecordingBubble({required this.recording, required this.alignRight, required this.score});

  @override
  State<_RecordingBubble> createState() => _RecordingBubbleState();
}

class _RecordingBubbleState extends State<_RecordingBubble> {
  final _player = AudioPlayer();
  bool _isPlaying = false;
  bool _loadingUrl = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.stop();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }
    setState(() => _loadingUrl = true);
    try {
      final url = await supabase.storage
          .from('voice-recordings')
          .createSignedUrl(widget.recording.audioStoragePath, 3600);
      await _player.play(UrlSource(url));
      if (!mounted) return;
      setState(() {
        _isPlaying = true;
        _loadingUrl = false;
      });
      _player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _isPlaying = false);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingUrl = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось воспроизвести: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: widget.alignRight ? AppColors.navy3 : AppColors.gold.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: _loadingUrl ? null : _togglePlay,
            icon: _loadingUrl
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_isPlaying ? Icons.stop : Icons.play_arrow, color: AppColors.gold),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.graphic_eq, size: 18, color: AppColors.muted),
          if (widget.score != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: AppColors.gold, borderRadius: BorderRadius.circular(6)),
              child: Text('${widget.score}', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800)),
            ),
          ],
        ],
      ),
    );

    return Align(
      alignment: widget.alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: bubble,
    );
  }
}
