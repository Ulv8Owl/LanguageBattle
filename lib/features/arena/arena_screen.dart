import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/game_access.dart';
import '../../core/leagues.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../widgets/chrolingo_widgets.dart';
import '../subscription/paywall_screen.dart';

class ArenaScreen extends StatefulWidget {
  const ArenaScreen({super.key});

  @override
  State<ArenaScreen> createState() => _ArenaScreenState();
}

class _ArenaScreenState extends State<ArenaScreen> {
  Map<String, dynamic>? _profile;
  WalletState _wallet = WalletState.empty;
  int _elo = 1000;
  List<Map<String, dynamic>> _matches = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final uid = currentUserId;
    try {
      final profile = await supabase.from('users').select().eq('id', uid).maybeSingle();
      // sync_wallet заодно досчитывает восстановленную энергию и отдаёт
      // актуальный статус подписки — считать это на клиенте нельзя.
      final wallet = await GameAccess.sync();
      final learning = await supabase
          .from('user_languages')
          .select('elo')
          .eq('user_id', uid)
          .eq('role', 'learning')
          .limit(1)
          .maybeSingle();
      final asPlayerA = await supabase
          .from('matches')
          .select()
          .eq('player_a_id', uid)
          .inFilter('status', ['in_progress', 'completed']);
      final asPlayerB = await supabase
          .from('matches')
          .select()
          .eq('player_b_id', uid)
          .inFilter('status', ['in_progress', 'completed']);
      final all = [...asPlayerA, ...asPlayerB];
      all.sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _wallet = wallet;
        _elo = (learning?['elo'] as int?) ?? 1000;
        _matches = all;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Единая точка входа в любой из трёх режимов. Пока пробный период
  /// действует или оформлена подписка — обычный поток; иначе вместо него
  /// показывается пейволл (задача 5 итерации: правило одинаково для ВСЕХ
  /// трёх режимов, включая Одиночную Игру).
  Future<void> _enterMode(String modeName, VoidCallback openNormalFlow) async {
    if (!_wallet.hasAccess) {
      await PaywallScreen.show(context, modeName);
      if (mounted) _load();
      return;
    }
    openNormalFlow();
  }

  void _showModeInfo({
    required String title,
    required String description,
    required String rounds,
    required String eloChange,
    required String coins,
    required String gameMode,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.navy2, AppColors.navy1],
          ),
          border: const Border(top: BorderSide(color: AppColors.gold)),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(color: AppColors.gold.withValues(alpha: 0.14), blurRadius: 50, offset: const Offset(0, -14)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: AppColors.lineStrong, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 16),
            Text(title, style: AppFonts.ui(fontSize: 21, weight: FontWeight.w800, color: AppColors.gold)),
            const SizedBox(height: 10),
            Text(description,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.5)),
            const SizedBox(height: 16),
            ChPanel(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _StatCol(value: rounds, label: 'раундов', color: AppColors.gold),
                  _StatCol(value: eloChange, label: 'ELO', color: AppColors.cyan),
                  _StatCol(value: coins, label: 'монет', color: AppColors.gold),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  context.push('/matchmaking/$gameMode');
                },
                child: const Text('Найти соперника'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.cream,
                  side: const BorderSide(color: AppColors.lineStrong),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.pop(sheetContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Позови друга в группу во вкладке «Друзья», '
                          'затем оба нажмите «Найти соперника»'),
                    ),
                  );
                },
                child: const Text('Пригласить друга в группу'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final xp = (_profile?['xp'] as int?) ?? 0;
    final level = 1 + xp ~/ 100;
    final levelProgress = (xp % 100) / 100;
    final league = leagueFor(_elo);
    final bandProgress = ((_elo - league.min) / (league.max - league.min)).clamp(0.0, 1.0);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          Row(
            children: [
              ChAvatar(
                name: (_profile?['username'] as String?) ?? '?',
                size: 40,
                ringColor: league.color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((_profile?['username'] as String?) ?? 'Игрок', style: AppFonts.ui(fontSize: 13)),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        SizedBox(
                          width: 60,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: levelProgress,
                              minHeight: 5,
                              backgroundColor: AppColors.navy1,
                              valueColor: const AlwaysStoppedAnimation(AppColors.gold),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text('$level LVL',
                            style: AppFonts.mono(fontSize: 9, color: AppColors.gold, weight: FontWeight.w700)),
                      ],
                    ),
                  ],
                ),
              ),
              ChPill(
                icon: const Icon(Icons.circle, size: 12, color: AppColors.gold),
                label: '${_wallet.coins}',
              ),
              const SizedBox(width: 6),
              ChPill(
                icon: const Icon(Icons.bolt, size: 12, color: AppColors.cyan),
                label: '${_wallet.energyCurrent}/${_wallet.energyMax}',
              ),
            ],
          ),
          if (_wallet.isTrial) ...[
            const SizedBox(height: 12),
            _TrialBanner(daysLeft: _wallet.trialDaysLeft),
          ] else if (!_wallet.hasAccess) ...[
            const SizedBox(height: 12),
            const _LockedBanner(),
          ],
          const SizedBox(height: 22),
          ChMenuRow(
            icon: const ChModeIcon(icon: Icons.school, gradient: [Color(0xFF5A6C99), Color(0xFF33426B)]),
            title: 'Одиночная Игра',
            onTap: () => _enterMode('Одиночная Игра', () async {
              await context.push('/training');
              if (mounted) _load();
            }),
          ),
          const SizedBox(height: 9),
          ChMenuRow(
            icon: const ChModeIcon(icon: Icons.bolt, gradient: [AppColors.cyan, Color(0xFF3A3A40)]),
            title: 'Состязание',
            onTap: () => _enterMode(
              'Состязание',
              () => _showModeInfo(
                title: 'Состязание',
                description: 'PvP против любого игрока с тем же изучаемым языком. '
                    '10 раундов, одно голосовое за раунд.',
                rounds: '10',
                eloChange: '±20',
                coins: '+100',
                gameMode: 'sparring',
              ),
            ),
          ),
          const SizedBox(height: 9),
          ChMenuRow(
            icon: const ChModeIcon(icon: Icons.local_fire_department, gradient: [AppColors.gold, Color(0xFFFFE066)]),
            title: 'Дуэль',
            flagship: true,
            onTap: () => _enterMode(
              'Дуэль',
              () => _showModeInfo(
                title: 'Дуэль',
                description: 'Бой против настоящего носителя изучаемого языка. '
                    '10 раундов, по два голосовых с каждой стороны.',
                rounds: '10',
                eloChange: '±24',
                coins: '+120',
                gameMode: 'native_duel',
              ),
            ),
          ),
          const SizedBox(height: 24),
          if (_matches.isNotEmpty) ...[
            Text('АКТИВНЫЕ БОИ', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 10),
            ..._matches.map((m) => _MatchRow(match: m)),
            const SizedBox(height: 20),
          ],
          Column(
            children: [
              Icon(Icons.emoji_events, size: 46, color: league.color),
              const SizedBox(height: 2),
              Text(league.name, style: AppFonts.ui(fontSize: 15, weight: FontWeight.w800, color: league.color)),
              const SizedBox(height: 9),
              Row(
                children: [
                  Text('${league.min}', style: AppFonts.mono(fontSize: 9)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: bandProgress,
                        minHeight: 11,
                        backgroundColor: AppColors.navy1,
                        valueColor: AlwaysStoppedAnimation(league.color),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(league.max > 90000 ? '∞' : '${league.max}', style: AppFonts.mono(fontSize: 9)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: leagueBands
                    .map((b) => Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3.5),
                          child: Icon(
                            Icons.emoji_events,
                            size: 20,
                            color: b.name == league.name ? b.color : b.color.withValues(alpha: 0.35),
                          ),
                        ))
                    .toList(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrialBanner extends StatelessWidget {
  final int daysLeft;

  const _TrialBanner({required this.daysLeft});

  @override
  Widget build(BuildContext context) {
    return ChPanel(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      child: Row(
        children: [
          const Icon(Icons.hourglass_bottom, size: 15, color: AppColors.gold),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Пробный период: осталось $daysLeft дн.',
              style: AppFonts.mono(fontSize: 10, color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _LockedBanner extends StatelessWidget {
  const _LockedBanner();

  @override
  Widget build(BuildContext context) {
    return ChPanel(
      borderColor: AppColors.danger,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 15, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Пробный период закончился — режимы закрыты',
              style: AppFonts.mono(fontSize: 10, color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCol extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _StatCol({required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: AppFonts.mono(fontSize: 14, weight: FontWeight.w700, color: color)),
        Text(label, style: const TextStyle(fontSize: 9, color: AppColors.muted)),
      ],
    );
  }
}

class _MatchRow extends StatelessWidget {
  final Map<String, dynamic> match;

  const _MatchRow({required this.match});

  @override
  Widget build(BuildContext context) {
    final status = match['status'] as String;
    final completed = status == 'completed';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ChPanel(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: InkWell(
          onTap: () => context.push(completed ? '/battle/${match['id']}/results' : '/battle/${match['id']}'),
          child: Row(
            children: [
              Icon(
                match['game_mode'] == 'native_duel' ? Icons.local_fire_department : Icons.bolt,
                color: AppColors.gold,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(match['game_mode'] == 'native_duel' ? 'Дуэль' : 'Состязание',
                        style: AppFonts.ui(fontSize: 12)),
                    Text(completed ? 'Завершён' : 'В процессе',
                        style: const TextStyle(fontSize: 10, color: AppColors.muted)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}
