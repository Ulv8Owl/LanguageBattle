import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import 'battle_models.dart';

class BattleResultsScreen extends StatefulWidget {
  final String matchId;

  const BattleResultsScreen({super.key, required this.matchId});

  @override
  State<BattleResultsScreen> createState() => _BattleResultsScreenState();
}

class _BattleResultsScreenState extends State<BattleResultsScreen> {
  bool _loading = true;
  String? _error;
  MatchData? _match;
  String _myName = 'Ты';
  String _opponentName = 'Соперник';
  List<RoundData> _rounds = [];
  List<RoundScoreData> _scores = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final myId = currentUserId;
      final matchRow =
          await supabase.from('matches').select().eq('id', widget.matchId).single();
      final match = MatchData.fromRow(matchRow);
      final opponentId = match.playerAId == myId ? match.playerBId : match.playerAId;

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

      final me = await supabase.from('users').select('username').eq('id', myId).maybeSingle();
      String opponentName = 'Соперник';
      if (opponentId != null) {
        final opp = await supabase
            .from('users')
            .select('username')
            .eq('id', opponentId)
            .maybeSingle();
        opponentName = (opp?['username'] as String?) ?? 'Соперник';
      }

      if (!mounted) return;
      setState(() {
        _match = match;
        _myName = (me?['username'] as String?) ?? 'Ты';
        _opponentName = opponentName;
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final m = _match;
    if (m == null) {
      return Scaffold(body: Center(child: Text(_error ?? 'Матч не найден')));
    }

    final myId = currentUserId;
    final opponentId = m.playerAId == myId ? m.playerBId : m.playerAId;
    var myTotal = 0;
    var opponentTotal = 0;
    for (final r in _rounds) {
      myTotal += _scoreFor(r.id, myId) ?? 0;
      opponentTotal += _scoreFor(r.id, opponentId) ?? 0;
    }

    final iWon = m.winnerId == myId;
    final draw = m.winnerId == null;

    return Scaffold(
      appBar: AppBar(title: const Text('Итоги матча')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: Text(
                draw ? 'НИЧЬЯ' : (iWon ? 'ПОБЕДА' : 'ПОРАЖЕНИЕ'),
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: draw ? AppColors.muted : (iWon ? AppColors.gold : AppColors.danger),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _TotalScore(name: _myName, score: myTotal, highlight: iWon),
                const Text('—', style: TextStyle(fontSize: 20, color: AppColors.muted)),
                _TotalScore(name: _opponentName, score: opponentTotal, highlight: !iWon && !draw),
              ],
            ),
            const SizedBox(height: 32),
            const Text('По раундам', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 12),
            ..._rounds.map((r) {
              final mine = _scoreFor(r.id, myId);
              final theirs = _scoreFor(r.id, opponentId);
              return Card(
                color: AppColors.navy2,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text('Раунд ${r.roundNumber}'),
                  subtitle: Text(r.generatedPhrase ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Text(
                    '${mine ?? '–'} : ${theirs ?? '–'}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              );
            }),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => context.go('/arena'),
              child: const Text('В Арену'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalScore extends StatelessWidget {
  final String name;
  final int score;
  final bool highlight;

  const _TotalScore({required this.name, required this.score, required this.highlight});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(name, style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 6),
        Text(
          '$score',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w800,
            color: highlight ? AppColors.gold : AppColors.cream,
          ),
        ),
      ],
    );
  }
}
