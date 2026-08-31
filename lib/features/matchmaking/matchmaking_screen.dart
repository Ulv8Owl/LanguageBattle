import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/game_access.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/phrase_bank.dart';
import '../../data/player_rating.dart';
import '../battle/battle_models.dart';
import '../../widgets/chrolingo_widgets.dart';

enum _Phase { searching, found, notFound, failed }

/// Живой поиск соперника (задача 3 итерации).
///
/// Объём этого захода намеренно ограничен: фоновый поиск с push-уведомлениями
/// и бот-соперник НЕ реализованы — если за 30 секунд живой соперник не нашёлся,
/// показывается "соперник не найден, попробуй позже" с кнопкой "Отмена".
///
/// Отказ/тайм-аут подтверждения одной стороны не наказывает другую: сервер
/// возвращает встречный тикет в очередь со свежим окном поиска вместо того,
/// чтобы отменять его тоже (deferred_suggestions.md, пункт 6 — реализовано
/// по отдельному запросу владельца проекта), см. `_onTicketUpdate`.
class MatchmakingScreen extends StatefulWidget {
  /// 'sparring' | 'native_duel'
  final String gameMode;

  const MatchmakingScreen({super.key, required this.gameMode});

  @override
  State<MatchmakingScreen> createState() => _MatchmakingScreenState();
}

class _MatchmakingScreenState extends State<MatchmakingScreen> {
  static const _searchLimit = Duration(seconds: 30);
  static const _acceptLimit = Duration(seconds: 20);

  _Phase _phase = _Phase.searching;
  String? _ticketId;
  String? _matchId;
  String _opponentName = 'Соперник';
  PlayerRating _opponentRating = PlayerRating.newcomer;
  String? _error;
  bool _accepting = false;
  bool _accepted = false;
  int _elapsed = 0;
  int _acceptLeft = _acceptLimit.inSeconds;

  Timer? _tick;
  Timer? _acceptTick;
  StreamSubscription? _matchSub;
  StreamSubscription? _ticketSub;
  bool _leaving = false;

  String get _modeName => widget.gameMode == 'native_duel' ? 'Дуэль' : 'Состязание';

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _acceptTick?.cancel();
    _matchSub?.cancel();
    _ticketSub?.cancel();
    // Тикет снимается всегда, даже если экран закрыли свайпом назад —
    // иначе игрок остался бы висеть в очереди для чужого поиска.
    final ticketId = _ticketId;
    if (ticketId != null && !_leaving) {
      supabase.rpc('mm_cancel', params: {'p_ticket_id': ticketId}).ignore();
    }
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final profile = await supabase
          .from('users')
          .select('native_language')
          .eq('id', currentUserId)
          .maybeSingle();
      final learning = await supabase
          .from('user_languages')
          .select('language_code, native_for, ${PlayerRating.columns}')
          .eq('user_id', currentUserId)
          .eq('role', 'learning')
          .eq('is_active', true)
          .limit(1)
          .maybeSingle();

      // native_for — родной язык ИМЕННО этой пары (миграция 0025), а не
      // общий профильный: у полиглота с несколькими родными активная пара
      // может быть anchored не на главном («японский от китайского», пока
      // главный родной — русский). Соперника в Дуэли ищем по родному ЭТОЙ
      // пары — иначе матч подобрал бы носителя не того языка, с которого
      // игрок на самом деле учит. null у пар, не тронутых после этой
      // миграции, — тогда откат на общий профильный.
      final nativeLanguage = (learning?['native_for'] as String?) ?? profile?['native_language'] as String?;
      final targetLanguage = learning?['language_code'] as String?;
      if (nativeLanguage == null || targetLanguage == null) {
        setState(() {
          _phase = _Phase.failed;
          _error = 'Сначала выбери языковую пару в онбординге.';
        });
        return;
      }

      // Фразы для раунда есть, только если уровень переведён на ОБА языка
      // пары — а переведены пока только en/ru/es. Проверяем ДО постановки
      // в очередь: найденный соперник уже реальный человек, и обрывать бой
      // на середине из-за пустой фразы куда хуже, чем не пустить в поиск.
      final level = PlayerRating.fromRow(learning).levelIndex;
      await PhraseBank.loadLevel(level);
      if (!PhraseBank.hasContentFor(level, nativeLanguage, targetLanguage)) {
        setState(() {
          _phase = _Phase.failed;
          _error = 'Для этой языковой пары пока нет фраз — контент на '
              'изучаемый и родной языки ещё не готов.';
        });
        return;
      }

      _ticketId = await supabase.rpc('mm_enqueue', params: {
        'p_game_mode': widget.gameMode,
        'p_native_language': nativeLanguage,
        'p_target_language': targetLanguage,
        'p_countrymen_only': false,
      }) as String;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = ServerErrors.isSubscriptionRequired(e)
            ? 'Нужна подписка, чтобы играть в этом режиме.'
            : 'Не удалось встать в очередь: $e';
      });
      return;
    }

    if (!mounted) return;
    // Следим за своим же тикетом: если встречная сторона откажется или не
    // успеет подтвердить, сервер (mm_cancel, см. 0007) вернёт НАШ тикет в
    // 'searching' вместо того, чтобы отменять и наш поиск тоже — не
    // подтверждённый матч не должен стоить нам уже потраченного времени.
    _ticketSub = supabase
        .from('matchmaking_tickets')
        .stream(primaryKey: ['id'])
        .eq('id', _ticketId!)
        .listen(_onTicketUpdate);
    _tick = Timer.periodic(const Duration(seconds: 2), (_) => _searchStep());
    _searchStep();
  }

  void _onTicketUpdate(List<Map<String, dynamic>> rows) {
    if (!mounted || rows.isEmpty || _leaving) return;
    final status = rows.first['status'] as String?;
    if (status == 'searching' && _phase != _Phase.searching) {
      _acceptTick?.cancel();
      _matchSub?.cancel();
      setState(() {
        _phase = _Phase.searching;
        _matchId = null;
        _accepted = false;
        _accepting = false;
        _elapsed = 0;
      });
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 2), (_) => _searchStep());
    } else if (status == 'expired' && _phase == _Phase.searching) {
      _tick?.cancel();
      setState(() => _phase = _Phase.notFound);
    }
  }

  /// Окно допустимой разницы рейтингов расширяется по ходу поиска
  /// (раздел 2.3), чтобы не искать вечно точное совпадение.
  ///
  /// Подбор идёт по САМОМУ рейтингу, а не по консервативной оценке: соперник
  /// нужен равный по силе, и осторожность системы к этому отношения не
  /// имеет. Шкала Glicko-2 совпадает со шкалой эло (те же ~400 очков на
  /// десятикратную разницу шансов), поэтому пороги окна остались прежними.
  int _eloWindowFor(int elapsedSeconds) {
    if (elapsedSeconds < 10) return 100;
    if (elapsedSeconds < 20) return 250;
    return 600;
  }

  Future<void> _searchStep() async {
    final ticketId = _ticketId;
    if (ticketId == null || _phase != _Phase.searching) return;

    _elapsed += 2;
    if (mounted) setState(() {});

    try {
      final result = await supabase.rpc('mm_search', params: {
        'p_ticket_id': ticketId,
        'p_elo_window': _eloWindowFor(_elapsed),
      });
      final map = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
      if (map['found'] == true && map['match_id'] != null) {
        await _onMatchFound(map['match_id'] as String);
        return;
      }
    } catch (e) {
      debugPrint('mm_search failed: $e');
    }

    if (_elapsed >= _searchLimit.inSeconds && _phase == _Phase.searching) {
      _tick?.cancel();
      try {
        await supabase.rpc('mm_cancel', params: {'p_ticket_id': ticketId});
      } catch (_) {
        // Тикет всё равно протух по expires_at — молча идём дальше.
      }
      if (mounted) setState(() => _phase = _Phase.notFound);
    }
  }

  Future<void> _onMatchFound(String matchId) async {
    _tick?.cancel();
    _matchId = matchId;

    try {
      final matchRow = await supabase.from('matches').select().eq('id', matchId).single();
      final match = MatchData.fromRow(matchRow);
      final opponentId = match.playerAId == currentUserId ? match.playerBId : match.playerAId;
      if (opponentId != null) {
        final opp = await supabase
            .from('users')
            .select('username')
            .eq('id', opponentId)
            .maybeSingle();
        _opponentName = (opp?['username'] as String?) ?? 'Соперник';
        // Рейтинг соперника ИМЕННО для языка этого матча — у игрока может быть
        // до 4 языковых пар с разным рейтингом, а нас интересует не то,
        // что у него сейчас "активно", а тот конкретный язык, на котором
        // будет идти бой.
        final targetLanguage = match.languageForSlot(opponentId, 'target');
        final oppLang = await supabase
            .from('user_languages')
            .select(PlayerRating.columns)
            .eq('user_id', opponentId)
            .eq('role', 'learning')
            .eq('language_code', targetLanguage)
            .limit(1)
            .maybeSingle();
        _opponentRating = PlayerRating.fromRow(oppLang);
      }
    } catch (e) {
      debugPrint('failed to load opponent card: $e');
    }

    if (!mounted) return;
    setState(() {
      _phase = _Phase.found;
      _acceptLeft = _acceptLimit.inSeconds;
    });

    // Матч стартует, когда приняли обе стороны — сервер переводит его в
    // in_progress, а мы узнаём об этом через Realtime, а не опросом.
    _matchSub = supabase
        .from('matches')
        .stream(primaryKey: ['id'])
        .eq('id', matchId)
        .listen((rows) {
      if (!mounted || rows.isEmpty) return;
      final status = rows.first['status'] as String?;
      if (status == 'in_progress') {
        _goToBattle(matchId);
      } else if (status == 'abandoned') {
        _acceptTick?.cancel();
        setState(() => _phase = _Phase.notFound);
      }
    });

    _acceptTick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _acceptLeft--);
      if (_acceptLeft <= 0) {
        t.cancel();
        _decline();
      }
    });
  }

  void _goToBattle(String matchId) {
    if (_leaving) return;
    _leaving = true;
    _acceptTick?.cancel();
    _matchSub?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.pushReplacement('/battle/$matchId');
    });
  }

  Future<void> _accept() async {
    final ticketId = _ticketId;
    if (ticketId == null || _accepting) return;
    setState(() => _accepting = true);
    try {
      final result = await supabase.rpc('mm_accept', params: {'p_ticket_id': ticketId});
      final map = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _accepted = true;
        _accepting = false;
      });
      if (map['both_accepted'] == true && _matchId != null) {
        _goToBattle(_matchId!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _accepting = false;
        _error = 'Не удалось принять матч: $e';
      });
    }
  }

  Future<void> _decline() async {
    final ticketId = _ticketId;
    _acceptTick?.cancel();
    if (ticketId != null) {
      try {
        await supabase.rpc('mm_cancel', params: {'p_ticket_id': ticketId});
      } catch (_) {
        // Матч уже мог быть отменён встречной стороной.
      }
    }
    if (mounted) setState(() => _phase = _Phase.notFound);
  }

  void _close() {
    _leaving = true;
    final ticketId = _ticketId;
    if (ticketId != null) {
      supabase.rpc('mm_cancel', params: {'p_ticket_id': ticketId}).ignore();
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/arena');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_modeName)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_phase) {
            _Phase.searching => _buildSearching(),
            _Phase.found => _buildFound(),
            _Phase.notFound => _buildNotFound(),
            _Phase.failed => _buildFailed(),
          },
        ),
      ),
    );
  }

  Widget _buildSearching() {
    final left = (_searchLimit.inSeconds - _elapsed).clamp(0, _searchLimit.inSeconds);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 96,
          width: 96,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const SizedBox(
                height: 96,
                width: 96,
                child: CircularProgressIndicator(strokeWidth: 3, color: AppColors.gold),
              ),
              Text('$left', style: AppFonts.mono(fontSize: 22, weight: FontWeight.w700, color: AppColors.gold)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('Ищем соперника', style: AppFonts.ui(fontSize: 17, weight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          'Окно рейтинга расширяется: ±${_eloWindowFor(_elapsed)}',
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: _outlinedStyle,
            onPressed: _close,
            child: const Text('Отмена'),
          ),
        ),
      ],
    );
  }

  Widget _buildFound() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Соперник найден', style: AppFonts.ui(fontSize: 19, weight: FontWeight.w800, color: AppColors.gold)),
        const SizedBox(height: 20),
        ChPanel(
          borderColor: AppColors.gold,
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          child: Row(
            children: [
              ChAvatar(name: _opponentName, size: 48, ringColor: AppColors.gold),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_opponentName, style: AppFonts.ui(fontSize: 15, weight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                        '${_opponentRating.display} ± ${_opponentRating.deviation.round()}',
                        style: AppFonts.mono(fontSize: 11, weight: FontWeight.w700, color: AppColors.gold)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (_accepted)
          Column(
            children: [
              const SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold),
              ),
              const SizedBox(height: 10),
              const Text('Ждём соперника…', style: TextStyle(color: AppColors.muted, fontSize: 12)),
            ],
          )
        else ...[
          Text('$_acceptLeft с', style: AppFonts.mono(fontSize: 16, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _accepting ? null : _accept,
              child: _accepting
                  ? const SizedBox(
                      height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Text('Принять'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(style: _outlinedStyle, onPressed: _decline, child: const Text('Отклонить')),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
        ],
      ],
    );
  }

  Widget _buildNotFound() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.person_search, size: 52, color: AppColors.muted),
        const SizedBox(height: 18),
        Text('Соперник не найден', style: AppFonts.ui(fontSize: 17, weight: FontWeight.w800)),
        const SizedBox(height: 8),
        const Text(
          'Попробуй позже — сейчас в очереди никого с подходящей языковой парой.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(style: _outlinedStyle, onPressed: _close, child: const Text('Отмена')),
        ),
      ],
    );
  }

  Widget _buildFailed() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.error_outline, size: 52, color: AppColors.danger),
        const SizedBox(height: 18),
        Text(
          _error ?? 'Не удалось начать поиск',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.cream, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(style: _outlinedStyle, onPressed: _close, child: const Text('Отмена')),
        ),
      ],
    );
  }
}

final ButtonStyle _outlinedStyle = OutlinedButton.styleFrom(
  foregroundColor: AppColors.cream,
  side: const BorderSide(color: AppColors.lineStrong),
  padding: const EdgeInsets.symmetric(vertical: 14),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
);
