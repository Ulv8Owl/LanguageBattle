import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/avatar_parts.dart';
import '../../data/chat.dart';
import '../../widgets/chrolingo_widgets.dart';
import '../../widgets/match_chat_panel.dart';
import 'battle_models.dart';
import 'player_card_sheet.dart';

/// Итоги матча: исход, счёт по сумме баллов и мини-чат с соперником.
///
/// ЧТО ЗДЕСЬ ГЛАВНОЕ И ПОЧЕМУ ИМЕННО ОНО. Экран отвечает на два вопроса:
/// «чем кончилось» и «что дальше». Первое — слово наверху и два числа под
/// ним; второе — мини-чат, из которого зовут на реванш. Разбор по раундам
/// отсюда убран: он был списком карточек с фразами, который никто не
/// читал, а место занимал ровно то, где теперь живёт чат.
///
/// СТОРОНЫ ПОСТОЯННЫ: соперник слева, игрок справа с золотой обводкой —
/// при любом исходе. Меняться местами победитель и проигравший не должны:
/// свою аватарку игрок ищет глазами всегда в одном месте.
class BattleResultsScreen extends StatefulWidget {
  final String matchId;

  const BattleResultsScreen({super.key, required this.matchId});

  @override
  State<BattleResultsScreen> createState() => _BattleResultsScreenState();
}

class _BattleResultsScreenState extends State<BattleResultsScreen> {
  final String _myId = currentUserId;

  bool _loading = true;
  String? _error;
  MatchData? _match;
  String _myName = 'Ты';
  String _opponentName = 'Соперник';
  Map<String, String> _myAvatar = const {};
  Map<String, String> _opponentAvatar = const {};
  List<RoundData> _rounds = [];
  List<RoundScoreData> _scores = [];

  /// Уже ушли в реванш — второй раз не уводим.
  bool _leftForRematch = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final matchRow =
          await supabase.from('matches').select().eq('id', widget.matchId).single();
      final match = MatchData.fromRow(matchRow);
      final opponentId = match.playerAId == _myId ? match.playerBId : match.playerAId;

      final roundsRows = await supabase
          .from('rounds')
          .select()
          .eq('match_id', widget.matchId)
          .order('round_number');
      final roundIds = roundsRows.map((r) => r['id'] as String).toList();

      List<Map<String, dynamic>> scoreRows = [];
      if (roundIds.isNotEmpty) {
        scoreRows =
            await supabase.from('round_scores').select().inFilter('round_id', roundIds);
      }

      final me = await supabase
          .from('users')
          .select('username, equipped_avatar')
          .eq('id', _myId)
          .maybeSingle();
      String opponentName = 'Соперник';
      Map<String, String> opponentAvatar = const {};
      if (opponentId != null) {
        final opp = await supabase
            .from('users')
            .select('username, equipped_avatar')
            .eq('id', opponentId)
            .maybeSingle();
        opponentName = (opp?['username'] as String?) ?? 'Соперник';
        opponentAvatar = avatarFromJson(opp?['equipped_avatar']);
      }

      if (!mounted) return;
      setState(() {
        _match = match;
        _myName = (me?['username'] as String?) ?? 'Ты';
        _myAvatar = avatarFromJson(me?['equipped_avatar']);
        _opponentName = opponentName;
        _opponentAvatar = opponentAvatar;
        _rounds = roundsRows.map(RoundData.fromRow).toList();
        _scores = scoreRows.map(RoundScoreData.fromRow).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить итоги: $e';
        _loading = false;
      });
    }
  }

  int? _scoreFor(String roundId, String? userId) {
    if (userId == null) return null;
    for (final s in _scores) {
      if (s.roundId == roundId && s.userId == userId) return s.score;
    }
    return null;
  }

  void _goToRematch(String newMatchId) {
    if (_leftForRematch || !mounted) return;
    _leftForRematch = true;
    context.go('/battle/$newMatchId');
  }

  Future<void> _offerRematch() async {
    try {
      await offerRematch(widget.matchId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Вызов не отправился: $e')),
      );
    }
  }

  void _openCard(String userId, bool isMe) {
    showPlayerCard(
      context,
      userId: userId,
      name: isMe ? _myName : _opponentName,
      isMe: isMe,
      // Реванш зовётся отсюда: соперник уже известен, звать его через
      // подбор значило бы, что «реванш» может свести с кем-то третьим.
      onRematch: isMe ? null : _offerRematch,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final m = _match;
    if (m == null) {
      return Scaffold(body: Center(child: Text(_error ?? 'Матч не найден')));
    }

    final opponentId = m.playerAId == _myId ? m.playerBId : m.playerAId;
    var myTotal = 0;
    var opponentTotal = 0;
    for (final r in _rounds) {
      myTotal += _scoreFor(r.id, _myId) ?? 0;
      opponentTotal += _scoreFor(r.id, opponentId) ?? 0;
    }

    // ИСХОД СЧИТАЕМ ПО СУММЕ БАЛЛОВ, а не по winner_id. Равные суммы — это
    // ничья, и назвать её поражением только потому, что сервер выбрал
    // победителя по выигранным раундам, было бы неправдой в лицо игроку.
    // Брошенный бой — исключение: там сумма ничего не говорит, потому что
    // баллы за большинство раундов не выставлялись вовсе.
    final forfeitedByMe = m.forfeitedBy != null && m.forfeitedBy == _myId;
    final forfeitedByThem = m.forfeitedBy != null && m.forfeitedBy != _myId;
    final _Outcome outcome;
    if (forfeitedByMe) {
      outcome = _Outcome.loss;
    } else if (forfeitedByThem) {
      outcome = _Outcome.win;
    } else if (myTotal > opponentTotal) {
      outcome = _Outcome.win;
    } else if (myTotal < opponentTotal) {
      outcome = _Outcome.loss;
    } else {
      outcome = _Outcome.draw;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Итоги матча')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                outcome.title,
                textAlign: TextAlign.center,
                style: AppFonts.ui(
                  fontSize: 34,
                  weight: FontWeight.w800,
                  color: outcome.color,
                ),
              ),
              const SizedBox(height: 18),
              _ScoreBoard(
                opponentName: _opponentName,
                opponentAvatar: _opponentAvatar,
                opponentTotal: opponentTotal,
                myName: _myName,
                myAvatar: _myAvatar,
                myTotal: myTotal,
                myColor: outcome.color,
                onOpponentTap:
                    opponentId == null ? null : () => _openCard(opponentId, false),
                onMyTap: () => _openCard(_myId, true),
              ),
              if (forfeitedByThem || forfeitedByMe) ...[
                const SizedBox(height: 10),
                Text(
                  forfeitedByThem
                      ? '$_opponentName покинул бой. Победа засчитана вам, '
                          'рейтинга начислено вдвое меньше, чем за доигранный бой.'
                      : 'Вы покинули бой. Поражение засчитано, '
                          'рейтинга потеряно вдвое меньше, чем за доигранный бой.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35),
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: opponentId == null
                    ? const SizedBox.shrink()
                    : MatchChatPanel(
                        matchId: widget.matchId,
                        myId: _myId,
                        opponentId: opponentId,
                        myName: _myName,
                        opponentName: _opponentName,
                        myAvatar: _myAvatar,
                        opponentAvatar: _opponentAvatar,
                        onAvatarTap: _openCard,
                        onRematchStarted: _goToRematch,
                      ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => context.go('/arena'),
                child: const Text('В Арену'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Исход матча глазами игрока. Цвет один и тот же и у слова, и у своего
/// числа в счёте: два разных цвета для одного и того же исхода читались бы
/// как два разных сообщения.
enum _Outcome {
  win('ПОБЕДА', AppColors.gold),
  loss('ПОРАЖЕНИЕ', AppColors.danger),
  draw('НИЧЬЯ', AppColors.cream);

  final String title;
  final Color color;

  const _Outcome(this.title, this.color);
}

/// Счёт за весь матч: аватарки по краям, суммы баллов между ними.
class _ScoreBoard extends StatelessWidget {
  final String opponentName;
  final Map<String, String> opponentAvatar;
  final int opponentTotal;
  final String myName;
  final Map<String, String> myAvatar;
  final int myTotal;

  /// Цвет своего числа — цвет исхода.
  final Color myColor;

  final VoidCallback? onOpponentTap;
  final VoidCallback? onMyTap;

  const _ScoreBoard({
    required this.opponentName,
    required this.opponentAvatar,
    required this.opponentTotal,
    required this.myName,
    required this.myAvatar,
    required this.myTotal,
    required this.myColor,
    required this.onOpponentTap,
    required this.onMyTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _face(opponentName, opponentAvatar, AppColors.lineStrong, onOpponentTap),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  '$opponentTotal',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.ui(fontSize: 40, weight: FontWeight.w800, color: AppColors.cream),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('/',
                    style: TextStyle(fontSize: 32, color: AppColors.muted, fontWeight: FontWeight.w700)),
              ),
              Flexible(
                child: Text(
                  '$myTotal',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.ui(fontSize: 40, weight: FontWeight.w800, color: myColor),
                ),
              ),
            ],
          ),
        ),
        // Своя аватарка всегда в золотой обводке — по ней игрок и находит
        // себя на экране, а не по тому, кто выиграл.
        _face(myName, myAvatar, AppColors.gold, onMyTap),
      ],
    );
  }

  Widget _face(String name, Map<String, String> avatar, Color ring, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ChAvatar(name: name, avatar: avatar, size: 78, ringColor: ring, glow: false),
          const SizedBox(height: 5),
          SizedBox(
            width: 84,
            child: Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}
