import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/languages.dart';
import '../../core/stream_rows.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/phrase_bank.dart';
import '../../data/player_rating.dart';
import '../../data/voice_submission.dart';
import '../../widgets/ai_avatar.dart';
import '../../widgets/chrolingo_widgets.dart';
import '../../widgets/transcript_review.dart';
import '../../widgets/voice_message_bubble.dart';
import '../../widgets/voice_recorder_dock.dart';
import 'battle_models.dart';
import 'player_card_sheet.dart';

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

  /// Уровень сложности фраз — лига игрока по изучаемому языку.
  int _phraseLevel = 0;
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

  /// Сколько секунд даётся игроку на ответ в раунде (не на длину самой
  /// записи). Спека называет 30-45 с, но пока оба игрока — это один человек
  /// с двумя телефонами, и записать надо в оба, так что на время отладки
  /// две минуты. Значение обязано совпадать с умолчанием
  /// auto_skip_stale_rounds (миграция 0020), иначе сервер спишет раунд
  /// раньше, чем на экране кончится отсчёт.
  static const _roundTimeoutSeconds = 120;

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
      supabase.rpc(
        'auto_skip_stale_rounds',
        params: {'p_timeout_seconds': _roundTimeoutSeconds},
      ).catchError((_) => null);
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

      final learning = await supabase
          .from('user_languages')
          .select(PlayerRating.columns)
          .eq('user_id', _myId)
          .eq('role', 'learning')
          .eq('is_active', true)
          .limit(1)
          .maybeSingle();
      _phraseLevel = PlayerRating.fromRow(learning).levelIndex;
      // В ленте встречаются фразы уже сыгранных раундов, а их уровень мог
      // отличаться (лига игрока меняется прямо по ходу серии матчей) —
      // поэтому грузим все уровни, а не только свой.
      await PhraseBank.loadAll();
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

    // Без .order(): у стрима supabase_flutter параметр ascending по
    // умолчанию FALSE, поэтому `.order('round_number')` давал раунды в
    // обратном порядке — новые сообщения уезжали вверх ленты. Порядок и
    // защиту от повторов держим сами: локальный кэш стрима успевал отдать
    // одну и ту же строку дважды, и раунд рисовался в ленте два раза.
    _roundsSub = supabase
        .from('rounds')
        .stream(primaryKey: ['id'])
        .eq('match_id', widget.matchId)
        .listen((rows) {
      if (!mounted) return;
      final rounds = dedupeById(rows).map(RoundData.fromRow).toList()
        ..sort((a, b) => a.roundNumber.compareTo(b.roundNumber));
      setState(() => _rounds = rounds);
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
        _recordings = dedupeById(rows)
            .where((r) => r['round_id'] != null)
            .map(VoiceRecordingData.fromRow)
            .toList();
      });
      _scrollToBottomSoon();
      _maybeAdvance();
    });

    _scoresSub = supabase.from('round_scores').stream(primaryKey: ['id']).listen((rows) {
      if (!mounted) return;
      setState(() => _scores = dedupeById(rows).map(RoundScoreData.fromRow).toList());
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

  int? _scoreFor(String roundId, String? userId) => _verdictFor(roundId, userId)?.score;

  /// Оценка раунда целиком: балл плюс короткий разбор от судьи. В PvP на
  /// экран идёт и то и другое — раньше показывался только балл, и от ИИ в
  /// бою не было ни слова, хотя судья его писал.
  RoundScoreData? _verdictFor(String roundId, String? userId) {
    if (userId == null) return null;
    for (final s in _scores) {
      if (s.roundId == roundId && s.userId == userId) return s;
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
    // Фраза по лиге игрока: в Медной лиге простое настоящее время, в Лиге
    // Мастеров — сложный синтаксис. Уровень берём свой: соперник в этом
    // режиме всегда из той же лиги, иначе матча бы не было.
    final phraseIndex = PhraseBank.randomIndexForLevel(_phraseLevel, exclude: usedIndices);
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
      // раундам, пересчёт рейтинга, начисление валюты/опыта): клиент не может
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

    return PopScope(
      // Системная кнопка «назад» — тот же выход из боя, что и стрелка.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(m.isDuel ? 'Дуэль' : 'Состязание'),
        // Своя стрелка: штатная просто закрывает экран, а выход из боя
        // теперь его завершает и должен спрашивать подтверждение.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _confirmLeave,
        ),
      ),
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
                myId: _myId,
                opponentId: opponentId,
                secondsLeft: _roundSecondsLeft,
              ),
              // Кнопка микрофона лежит ПОВЕРХ ленты, а не отдельной полосой
              // под ней: полоса во всю ширину отрезала кусок переписки без
              // всякой пользы. Нижний отступ списка оставляет место, чтобы
              // последнее сообщение не пряталось под кнопкой, а слева и
              // справа от неё лента видна и прокручивается как обычно.
              Expanded(
                child: Stack(
                  children: [
                    if (_rounds.isEmpty)
                      const Center(child: CircularProgressIndicator())
                    else
                      ListView(
                        controller: _feedController,
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 108),
                        children: _buildFeed(m, opponentId),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 14,
                      child: Center(
                        child: VoiceRecorderDock(
                          key: _dockKey,
                          enabled: canRecord,
                          onSend: _sendTake,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// Выход из боя = поражение. Спрашиваем прежде, чем это случится:
  /// стрелка «назад» раньше просто сворачивала бой, и нажать её случайно
  /// ничего не стоило.
  Future<void> _confirmLeave() async {
    final m = _match;
    // Бой уже завершён (доигран или соперник вышел) — уходить не с чего.
    if (m == null || m.status != 'in_progress') {
      if (mounted) _leaveScreen();
      return;
    }

    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.navy2,
        title: const Text('Покинуть бой?'),
        content: const Text(
          'Вы автоматически проиграете, если покинете этот бой. '
          'Рейтинга потеряется вдвое меньше, чем при обычном поражении, '
          'а сопернику засчитают победу.',
          style: TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Остаться'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Покинуть'),
          ),
        ],
      ),
    );
    if (leave != true || !mounted) return;

    // Сдача засчитывается на сервере: соперник узнает о ней из того же
    // стрима матча, что и о честном завершении, — отдельного уведомления
    // не нужно.
    try {
      await supabase.rpc('forfeit_match', params: {'p_match_id': widget.matchId});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось выйти из боя: $e')),
      );
      return;
    }
    if (!mounted) return;
    // На экран итогов ведёт подписка на матч (статус стал completed), так
    // что здесь просто не мешаем.
    _navigatedAway = true;
    context.go('/battle/${widget.matchId}/results');
  }

  void _leaveScreen() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/arena');
    }
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
        // Подпись «Переведи на …» — только когда следующим идёт перевод. В
        // Дуэли вторым слотом игрок читает ту же фразу на родном языке, и
        // «переведи на русский» там было бы прямо неверной инструкцией: об
        // этом шаге говорит отдельная реплика хамелеона.
        targetLanguage:
            isCurrent && slot == 'target' ? m.languageForSlot(_myId, slot!) : null,
      ));
      // Голосовые раунда — в порядке отправки, а не «сначала мои, потом
      // чужие»: лента изображает переписку, и кто ответил первым, тот и
      // выше. Раньше своё голосовое всегда стояло над чужим, даже если
      // соперник ответил раньше.
      final spoken = _recordings.where((r) => r.roundId == round.id).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      for (final rec in spoken) {
        final isMine = rec.userId == _myId;
        if (!isMine && rec.userId != opponentId) continue;
        items.add(VoiceMessageBubble(
          key: ValueKey(rec.id),
          audioStoragePath: rec.audioStoragePath,
          name: isMine ? _myName : _opponentName,
          // Свои сообщения справа, чужие слева — как в любом мессенджере.
          alignRight: isMine,
        ));

        // В Дуэли за переводом идёт та же фраза на родном языке. Пока она
        // не записана, разбор перевода не показываем: он бы отвлекал ровно
        // в тот момент, когда надо говорить дальше. Оценка при этом уже
        // считается на сервере, так что ждать её потом почти не придётся.
        if (m.isDuel) {
          final nativeDone = _recordingFor(round.id, rec.userId, 'native') != null;
          if (rec.recordingSlot == 'target' && !nativeDone) {
            if (isMine) {
              items.add(const _AiNote(
                key: ValueKey('await-native'),
                text: 'Прочитай ещё раз текст, но уже на своём языке',
              ));
            }
            continue;
          }
          if (rec.recordingSlot == 'native') {
            // Родное голосовое соперника — это и есть образец носителя на
            // ТВОЁМ изучаемом языке: в Дуэли родной язык одного всегда
            // изучаемый для другого. Под своим таким же голосовым подпись
            // не нужна — себя носителем слушать незачем.
            if (!isMine) {
              items.add(_AiNote(
                key: ValueKey('${rec.id}-native-note'),
                text: 'Запись голоса носителя ↑',
              ));
            }
            continue;
          }
        }

        // Балл ставится только за голосовое на изучаемом языке — родное
        // в Дуэли соперник просто слушает (раздел 2.4).
        if (rec.recordingSlot != 'target') continue;
        items.add(_AiVerdict(
          key: ValueKey('${rec.id}-verdict'),
          name: isMine ? _myName : _opponentName,
          recording: rec,
          verdict: _verdictFor(round.id, rec.userId),
        ));
      }
    }
    return items;
  }
}

/// Короткая реплика хамелеона в ленте — подсказка, что делать дальше.
///
/// Живёт только на экране и не пишется в базу: обе такие подсказки
/// адресованы одному игроку («прочитай теперь на своём языке» — тому, кто
/// записывает; «запись голоса носителя» — тому, кто слушает), а сообщение
/// в общей ленте увидели бы оба.
class _AiNote extends StatelessWidget {
  final String text;

  const _AiNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 40, top: feedGap / 2, bottom: feedGap / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AiAvatar(),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: const BoxDecoration(
                color: AppColors.navy3,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(14),
                ),
              ),
              child: Text(
                text,
                style: const TextStyle(color: AppColors.cream, fontSize: 13, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Оценка одного голосового — отдельным сообщением ПОД ним, а не значком
/// на самом голосовом.
///
/// Так сделано по двум причинам. Балл на пузыре не оставлял места разбору,
/// и разбор от ИИ в бою не показывался вообще, хотя судья его писал. А
/// крутящийся индикатор на пузыре читался как «голосовое ещё грузится», а
/// не «ИИ его оценивает».
///
/// Сообщение всегда слева и с аватаром хамелеона: это говорит ИИ, а не
/// игрок, — по тому же правилу, что и фраза раунда.
class _AiVerdict extends StatelessWidget {
  /// Чьё голосовое разбирают — иначе в бою непонятно, чей это балл.
  final String name;

  /// Сама запись: из неё берутся распознанный текст и правка.
  final VoiceRecordingData recording;

  /// null — оценки ещё нет, судья считает.
  final RoundScoreData? verdict;

  const _AiVerdict({super.key, required this.name, required this.recording, required this.verdict});

  @override
  Widget build(BuildContext context) {
    final score = verdict?.score;

    return Padding(
      padding: const EdgeInsets.only(right: 40, top: feedGap / 2, bottom: feedGap / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AiAvatar(),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.navy3,
                border: Border.all(color: AppColors.line),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(14),
                ),
              ),
              child: score == null
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          height: 13,
                          width: 13,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold),
                        ),
                        const SizedBox(width: 9),
                        Text(
                          'Оценка от ИИ',
                          style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.muted),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.gold,
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Text(
                                '$score',
                                style: AppFonts.ui(fontSize: 12, weight: FontWeight.w800, color: Colors.black),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              name,
                              style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.muted),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // В бою — только разбор, без текстовых пояснений:
                        // сравнить свою фразу с правильной можно за секунду,
                        // а читать абзац объяснений посреди матча некогда.
                        TranscriptReview(
                          transcript: recording.transcript,
                          spoken: recording.spokenForDiff,
                          corrected: recording.correctedText,
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Шапка: живой счёт ВЫИГРАННЫХ РАУНДОВ, между кружками — разделитель, под
/// ними — обратный отсчёт до автосписания раунда (задача 5 итерации).
class _ScoreHeader extends StatelessWidget {
  final int myWins;
  final int opponentWins;
  final String myName;
  final String opponentName;
  final String myId;
  final String? opponentId;
  final int? secondsLeft;

  const _ScoreHeader({
    required this.myWins,
    required this.opponentWins,
    required this.myName,
    required this.opponentName,
    required this.myId,
    required this.opponentId,
    required this.secondsLeft,
  });

  @override
  Widget build(BuildContext context) {
    // Шапка занимала четверть экрана боя: отдельная строка под таймер
    // добавляла к её высоте столько же, сколько имена под аватарками.
    // Таймер переехал под счёт — в ту же строку, что и аватарки, — и
    // высота стала определяться только ими.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Соперник слева, ты справа — как и сообщения в ленте.
          Expanded(
            child: _PlayerSide(
              name: opponentName,
              userId: opponentId,
              color: AppColors.cyan,
              isMe: false,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$opponentWins',
                        style: AppFonts.ui(fontSize: 34, weight: FontWeight.w800, color: AppColors.cream)),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 7),
                      child: Text('/',
                          style: TextStyle(fontSize: 28, color: AppColors.muted, fontWeight: FontWeight.w700)),
                    ),
                    Text('$myWins',
                        style: AppFonts.ui(fontSize: 34, weight: FontWeight.w800, color: AppColors.gold)),
                  ],
                ),
                if (secondsLeft != null) ...[
                  const SizedBox(height: 4),
                  _RoundCountdown(seconds: secondsLeft!),
                ],
              ],
            ),
          ),
          Expanded(
            child: _PlayerSide(
              name: myName,
              userId: myId,
              color: AppColors.gold,
              isMe: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// Аватарка участника в шапке с именем под ней. По нажатию открывается
/// публичная карточка — рейтинг, лига, языковая пара, а у соперника ещё и
/// приглашение в друзья.
class _PlayerSide extends StatelessWidget {
  final String name;
  final String? userId;
  final Color color;
  final bool isMe;

  const _PlayerSide({
    required this.name,
    required this.userId,
    required this.color,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final id = userId;
    return GestureDetector(
      onTap: id == null
          ? null
          : () => showPlayerCard(context, userId: id, name: name, isMe: isMe),
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          // Без свечения: в шапке кружки крупные и стоят вплотную к ленте,
          // и ореол вокруг них размывал границу с сообщениями. У аватарок
          // в самой ленте свечение остаётся — там оно и различает своё
          // сообщение от чужого.
          ChAvatar(name: name, size: 54, ringColor: color, glow: false),
          const SizedBox(height: 5),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.muted),
          ),
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
      padding: const EdgeInsets.symmetric(vertical: feedGap / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AiAvatar(),
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
                  if (targetLanguage != null) ...[
                    Text(
                      translateToLabel(targetLanguage!),
                      style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.gold),
                    ),
                    const SizedBox(height: 5),
                  ],
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

/// Голосовое в ленте: своё — слева с аватаром и волной, соперника — справа
/// зеркально. Балл за раунд прикрепляется к сообщению сразу после оценки.
