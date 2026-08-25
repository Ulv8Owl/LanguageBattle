import 'package:flutter/material.dart';

import '../../core/game_access.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Награды (раздел 5.1, п.6). Battle Pass показывается как «Очки Победы: X
/// из 10» — это сезонная шкала 0-10, а не уровень игрока. Очко даётся за
/// выигранный матч (начисляет finalize_match на сервере).
///
/// Трек вех — две ветки: бесплатная и подписочная. Подписочная ветка
/// открыта, пока действует подписка/пробный период.
class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> {
  static const _maxPoints = 10;

  bool _loading = true;
  int _points = 0;
  String _seasonName = 'Сезон 1';
  bool _hasPremium = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final wallet = await GameAccess.sync();
      final seasonId = await supabase.rpc('current_season');
      int points = 0;
      String seasonName = 'Сезон 1';
      if (seasonId is String) {
        final season = await supabase
            .from('battle_pass_seasons')
            .select('season_name')
            .eq('id', seasonId)
            .maybeSingle();
        seasonName = (season?['season_name'] as String?) ?? seasonName;
        final progress = await supabase
            .from('battle_pass_progress')
            .select('tier')
            .eq('user_id', currentUserId)
            .eq('season_id', seasonId)
            .maybeSingle();
        points = (progress?['tier'] as int?) ?? 0;
      }
      if (!mounted) return;
      setState(() {
        _points = points;
        _seasonName = seasonName;
        _hasPremium = wallet.hasAccess;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Награды', style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800)),
          const SizedBox(height: 14),
          ChPanel(
            borderColor: AppColors.gold,
            boxShadow: [BoxShadow(color: AppColors.gold.withValues(alpha: 0.16), blurRadius: 22)],
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('BATTLE PASS · ${_seasonName.toUpperCase()}',
                    style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
                const SizedBox(height: 10),
                Text('Очки Победы: $_points из $_maxPoints',
                    style: AppFonts.ui(fontSize: 17, weight: FontWeight.w800)),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _points / _maxPoints,
                    minHeight: 8,
                    backgroundColor: AppColors.navy1,
                    valueColor: const AlwaysStoppedAnimation(AppColors.gold),
                  ),
                ),
                const SizedBox(height: 6),
                Text('Очко даётся за каждый выигранный матч',
                    style: AppFonts.mono(fontSize: 9, color: AppColors.muted)),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text('ТРЕК НАГРАД', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 10),
          _RewardTrack(points: _points, maxPoints: _maxPoints, hasPremium: _hasPremium),
          const SizedBox(height: 18),
          Text('ЕЖЕДНЕВНЫЕ ЗАДАНИЯ',
              style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 10),
          const ChPanel(
            child: Text(
              'Дневные и недельные квесты (раздел 2.6) в этот заход не входили — '
              'здесь появится их список с прогресс-барами.',
              style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// Трек с вехами: верхняя строка — бесплатная ветка, нижняя — подписочная.
class _RewardTrack extends StatelessWidget {
  final int points;
  final int maxPoints;
  final bool hasPremium;

  const _RewardTrack({required this.points, required this.maxPoints, required this.hasPremium});

  static const _freeRewards = [
    (icon: Icons.circle, label: '50'),
    (icon: Icons.bolt, label: '+1'),
    (icon: Icons.circle, label: '80'),
    (icon: Icons.emoji_emotions, label: 'Эмоция'),
    (icon: Icons.circle, label: '120'),
    (icon: Icons.bolt, label: '+2'),
    (icon: Icons.circle, label: '150'),
    (icon: Icons.emoji_emotions, label: 'Эмоция'),
    (icon: Icons.circle, label: '200'),
    (icon: Icons.workspace_premium, label: 'Рамка'),
  ];

  static const _premiumRewards = [
    (icon: Icons.circle, label: '150'),
    (icon: Icons.face_retouching_natural, label: 'Часть'),
    (icon: Icons.circle, label: '200'),
    (icon: Icons.workspace_premium, label: 'Рамка'),
    (icon: Icons.circle, label: '250'),
    (icon: Icons.emoji_emotions, label: 'Эмоция'),
    (icon: Icons.circle, label: '300'),
    (icon: Icons.face_retouching_natural, label: 'Часть'),
    (icon: Icons.circle, label: '400'),
    (icon: Icons.military_tech, label: 'Титул'),
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(maxPoints, (i) {
          final tier = i + 1;
          final unlocked = points >= tier;
          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Column(
              children: [
                Text('$tier', style: AppFonts.mono(fontSize: 9, color: unlocked ? AppColors.gold : AppColors.muted)),
                const SizedBox(height: 5),
                _Milestone(
                  icon: _freeRewards[i].icon,
                  label: _freeRewards[i].label,
                  unlocked: unlocked,
                  locked: false,
                ),
                const SizedBox(height: 6),
                _Milestone(
                  icon: _premiumRewards[i].icon,
                  label: _premiumRewards[i].label,
                  unlocked: unlocked && hasPremium,
                  locked: !hasPremium,
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _Milestone extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool unlocked;

  /// true для подписочной ветки без активной подписки — веха видна, но
  /// помечена замком.
  final bool locked;

  const _Milestone({required this.icon, required this.label, required this.unlocked, required this.locked});

  @override
  Widget build(BuildContext context) {
    final color = unlocked ? AppColors.gold : AppColors.muted;
    return Container(
      height: 58,
      width: 58,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: unlocked ? AppColors.gold : AppColors.line, width: 1.5),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: unlocked
              ? [AppColors.goldSoft, AppColors.navy1.withValues(alpha: 0.55)]
              : [AppColors.navy3.withValues(alpha: 0.5), AppColors.navy1.withValues(alpha: 0.5)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon, size: 20, color: color),
              if (locked)
                const Positioned(right: -6, top: -4, child: Icon(Icons.lock, size: 10, color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.mono(fontSize: 8, color: color),
          ),
        ],
      ),
    );
  }
}
