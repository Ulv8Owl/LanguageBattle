import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/game_access.dart';
import '../../core/app_events.dart';
import '../../core/leagues.dart';
import '../../widgets/league_trophy.dart';
import '../../core/nav_state.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/player_rating.dart';
import '../../widgets/chrolingo_widgets.dart';

class ArenaScreen extends StatefulWidget {
  const ArenaScreen({super.key});

  @override
  State<ArenaScreen> createState() => _ArenaScreenState();
}

/// Ключи режимов — используются и для навигации/gate-логики, и для того,
/// какая строка сейчас подсвечена (задача итерации, п.6: по умолчанию
/// ничего не подсвечено, подсветка появляется только пока открыта плашка
/// этого режима).
enum _ModeKey { training, solo, sparring, duel }

class _ArenaScreenState extends State<ArenaScreen> {
  Map<String, dynamic>? _profile;
  WalletState _wallet = WalletState.empty;
  PlayerRating _rating = PlayerRating.newcomer;
  bool _loading = true;

  /// null — ничего не подсвечено. Задаётся на время, пока открыта плашка
  /// режима, и сбрасывается, когда она закрывается любым способом.
  _ModeKey? _selectedMode;

  @override
  void initState() {
    super.initState();
    _load();
    profileRevision.addListener(_load);
    // Смена языковой пары в Профиле должна сразу отразиться на Арене
    // (рейтинг, доступность режимов) — Арена не пересоздаётся при
    // переключении вкладок (IndexedStack), поэтому слушаем нотификатор.
    languagePairVersion.addListener(_load);
  }

  @override
  void dispose() {
    profileRevision.removeListener(_load);
    languagePairVersion.removeListener(_load);
    super.dispose();
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
          .select(PlayerRating.columns)
          .eq('user_id', uid)
          .eq('role', 'learning')
          .eq('is_active', true)
          .limit(1)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _wallet = wallet;
        _rating = PlayerRating.fromRow(learning);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Единственная точка входа в любой из четырёх режимов. Тренировка не
  /// использует AI (нет ASR/LLM пайплайна вообще), поэтому она никогда не
  /// закрывается пробным периодом — три остальных режима закрываются,
  /// когда подписка/пробный период не активны (задача итерации, п.4/п.7).
  void _onModeTap(_ModeKey key, {required bool aiGated, required WidgetBuilder sheetBuilder}) {
    setState(() => _selectedMode = key);
    final locked = aiGated && !_wallet.hasAccess;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: locked ? _buildPaywallSheet : sheetBuilder,
    ).whenComplete(() {
      if (mounted) setState(() => _selectedMode = null);
    });
  }

  // -------------------------------------------------------------------
  // Плашки режимов
  // -------------------------------------------------------------------

  Widget _sheetChrome({
    required BuildContext sheetContext,
    required String title,
    required String description,
    required List<_Stat> stats,
    required String primaryLabel,
    required VoidCallback onPrimary,
    VoidCallback? onInviteFriend,
    Color accent = AppColors.gold,
    Widget? extraContent,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.navy2, AppColors.navy1],
        ),
        border: Border(top: BorderSide(color: accent)),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(color: accent.withValues(alpha: 0.14), blurRadius: 50, offset: const Offset(0, -14)),
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
          Text(title, style: AppFonts.ui(fontSize: 21, weight: FontWeight.w800, color: accent)),
          const SizedBox(height: 10),
          Text(description,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.5)),
          const SizedBox(height: 16),
          ChPanel(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: stats.map((s) => _StatCol(value: s.value, label: s.label, color: s.color)).toList(),
            ),
          ),
          if (extraContent != null) ...[
            const SizedBox(height: 14),
            extraContent,
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(sheetContext);
                onPrimary();
              },
              child: Text(primaryLabel),
            ),
          ),
          if (onInviteFriend != null) ...[
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
                  onInviteFriend();
                },
                child: const Text('Пригласить друга в группу'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTrainingSheet(BuildContext sheetContext) {
    // По умолчанию — 1000 слов текущей лиги игрока; ниже своей лиги можно
    // потренировать более простой набор, выше — нельзя (там ещё нечего
    // покупать, см. word_pack_price/league_locked).
    final maxLevel = _rating.levelIndex;
    var selectedLevel = maxLevel;

    return StatefulBuilder(
      builder: (context, setSheetState) {
        return _sheetChrome(
          sheetContext: sheetContext,
          title: 'Тренировка',
          description: 'Карточки со словами на твоей языковой паре: смотришь слово, '
              'вспоминаешь перевод, переворачиваешь. Не тратит энергию и работает '
              'без подписки.',
          stats: const [
            _Stat(value: '1000', label: 'слов в наборе', color: AppColors.gold),
            _Stat(value: '0', label: 'энергии', color: AppColors.ok),
          ],
          extraContent: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i <= maxLevel; i++)
                ChoiceChip(
                  label: Text(leagueBands[i].shortName),
                  selected: selectedLevel == i,
                  selectedColor: leagueBands[i].color.withValues(alpha: 0.25),
                  side: BorderSide(color: selectedLevel == i ? leagueBands[i].color : AppColors.lineStrong),
                  labelStyle: AppFonts.mono(
                    fontSize: 10,
                    weight: FontWeight.w700,
                    color: selectedLevel == i ? leagueBands[i].color : AppColors.muted,
                  ),
                  backgroundColor: Colors.transparent,
                  onSelected: (_) => setSheetState(() => selectedLevel = i),
                ),
            ],
          ),
          primaryLabel: 'Начать',
          onPrimary: () {
            trainingLevelRequest.value = selectedLevel;
            context.push('/flashcards');
          },
          accent: AppColors.ok,
        );
      },
    );
  }

  Widget _buildSoloSheet(BuildContext sheetContext) {
    return _sheetChrome(
      sheetContext: sheetContext,
      title: 'Одиночная Игра',
      description: 'Практика с AI-фидбеком, вне рейтинга. Две попытки на фразу: '
          'после первой — подробный разбор ошибок, вторая идёт в зачёт.',
      stats: const [
        _Stat(value: '5', label: 'раундов', color: AppColors.gold),
        _Stat(value: '—', label: 'рейтинг', color: AppColors.cyan),
        // Энергия платит за ответ, а не за вход: одно распознанное
        // голосовое — одна единица (миграция 0032).
        _Stat(value: '1', label: 'энергии за ответ', color: AppColors.cyan),
      ],
      primaryLabel: 'Начать',
      onPrimary: () async {
        await context.push('/training');
        if (mounted) _load();
      },
    );
  }

  Widget _buildSparringSheet(BuildContext sheetContext) {
    return _sheetChrome(
      sheetContext: sheetContext,
      title: 'Состязание',
      description: 'PvP против любого игрока с тем же изучаемым языком. '
          '10 раундов, одно голосовое за раунд.',
      stats: [
        const _Stat(value: '10', label: 'раундов', color: AppColors.gold),
        // Не константа: цена матча (K) выше первые десять матчей и ниже
        // в Алмазе — см. PlayerRating.estimatedSwing.
        _Stat(value: '±${_rating.estimatedSwing}', label: 'рейтинга', color: AppColors.cyan),
        const _Stat(value: '+100', label: 'монет', color: AppColors.gold),
      ],
      primaryLabel: 'Найти соперника',
      onPrimary: () => context.push('/matchmaking/sparring'),
      onInviteFriend: () => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Позови друга в группу во вкладке «Друзья», '
              'затем оба нажмите «Найти соперника»'),
        ),
      ),
    );
  }

  Widget _buildDuelSheet(BuildContext sheetContext) {
    return _sheetChrome(
      sheetContext: sheetContext,
      title: 'Дуэль',
      description: 'Бой против настоящего носителя изучаемого языка. '
          '10 раундов, по два голосовых с каждой стороны.',
      stats: [
        const _Stat(value: '10', label: 'раундов', color: AppColors.gold),
        _Stat(value: '±${_rating.estimatedSwing}', label: 'рейтинга', color: AppColors.cyan),
        const _Stat(value: '+120', label: 'монет', color: AppColors.gold),
      ],
      primaryLabel: 'Найти соперника',
      onPrimary: () => context.push('/matchmaking/native_duel'),
      onInviteFriend: () => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Позови друга в группу во вкладке «Друзья», '
              'затем оба нажмите «Найти соперника»'),
        ),
      ),
    );
  }

  /// Плашка вместо описания режима, когда пробный период кончился и
  /// подписки нет (задача итерации, п.7). Показывается для ВСЕХ трёх
  /// AI-режимов одинаково.
  Widget _buildPaywallSheet(BuildContext sheetContext) {
    return _sheetChrome(
      sheetContext: sheetContext,
      title: 'Пробный период закончился',
      description: 'Режимы с подключённым ИИ — Одиночная Игра, Состязание и '
          'Дуэль — заблокированы до оплаты подписки. Тренировка по-прежнему '
          'доступна бесплатно, а подписку можно оформить, если сочтёшь нужным.',
      stats: const [],
      primaryLabel: 'Подписка',
      onPrimary: openShopSubscription,
      accent: AppColors.danger,
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
    final league = _rating.league;

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
          if (!_wallet.hasAccess && !_wallet.isTrial) ...[
            const SizedBox(height: 12),
            const _LockedBanner(),
          ],
          const SizedBox(height: 22),
          ChMenuRow(
            icon: const ChModeIcon(icon: Icons.style, gradient: [AppColors.ok, Color(0xFF2E7D52)]),
            title: 'Тренировка',
            flagship: _selectedMode == _ModeKey.training,
            onTap: () => _onModeTap(_ModeKey.training, aiGated: false, sheetBuilder: _buildTrainingSheet),
          ),
          const SizedBox(height: 9),
          ChMenuRow(
            icon: const ChModeIcon(icon: Icons.school, gradient: [AppColors.gold, Color(0xFFFFE066)]),
            title: 'Одиночная Игра',
            flagship: _selectedMode == _ModeKey.solo,
            onTap: () => _onModeTap(_ModeKey.solo, aiGated: true, sheetBuilder: _buildSoloSheet),
          ),
          const SizedBox(height: 9),
          ChMenuRow(
            icon: const ChModeIcon(icon: Icons.bolt, gradient: [AppColors.gold, Color(0xFFFFE066)]),
            title: 'Состязание',
            flagship: _selectedMode == _ModeKey.sparring,
            onTap: () => _onModeTap(_ModeKey.sparring, aiGated: true, sheetBuilder: _buildSparringSheet),
          ),
          const SizedBox(height: 9),
          ChMenuRow(
            icon: const ChModeIcon(icon: Icons.local_fire_department, gradient: [AppColors.gold, Color(0xFFFFE066)]),
            title: 'Дуэль',
            flagship: _selectedMode == _ModeKey.duel,
            onTap: () => _onModeTap(_ModeKey.duel, aiGated: true, sheetBuilder: _buildDuelSheet),
          ),
          const SizedBox(height: 24),
          // Список «Активные бои» убран: незавершённых боёв больше не
          // бывает. Выход из боя завершает его сразу (forfeit_match,
          // миграция 0021), так что возвращаться некуда — а список,
          // предлагавший вернуться в бой, который соперник уже не ждёт,
          // только вводил в заблуждение.
          Column(
            children: [
              LeagueTrophy(league: league, size: 88),
              const SizedBox(height: 6),
              Text(
                league.titleWithLevel,
                style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800, color: league.color),
              ),
              const SizedBox(height: 12),
              // Полоса анимированная: сдвиг за матч мал по сравнению с
              // шириной лиги, и без движения он на глаз неотличим от
              // полной неподвижности.
              _LeagueProgress(rating: _rating),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final b in leagueBands)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: LeagueTrophy(
                        league: b,
                        size: 46,
                        active: b.name == league.name,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Полоса продвижения внутри лиги: слева порог входа, справа порог
/// следующей.
///
/// На Эло рейтинг игрока и рейтинг, по которому считается лига, — одно и
/// то же число, поэтому подпись под полосой одна. На Glicko-2 их было два
/// (показанный рейтинг и консервативная оценка rating - 2*RD), и полосе
/// приходилось объяснять игроку, почему они разошлись.
class _LeagueProgress extends StatelessWidget {
  final PlayerRating rating;

  const _LeagueProgress({required this.rating});

  @override
  Widget build(BuildContext context) {
    final league = rating.league;
    final progress = rating.bandProgress;
    final toNext = rating.toNextLeague;
    return Column(
      children: [
        Row(
          children: [
            Text('${league.min}', style: AppFonts.mono(fontSize: 10, color: AppColors.muted)),
            const SizedBox(width: 10),
            Expanded(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    children: [
                      Container(height: 14, color: AppColors.navy1),
                      FractionallySizedBox(
                        widthFactor: value,
                        child: Container(
                          height: 14,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [league.color.withValues(alpha: 0.55), league.color],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              league.max > 90000 ? '∞' : '${league.max}',
              style: AppFonts.mono(fontSize: 10, color: AppColors.muted),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Рейтинг ${rating.display}',
          style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: AppColors.cream),
        ),
        const SizedBox(height: 2),
        Text(
          toNext == null
              ? 'Выше лиг нет'
              : 'До лиги «${_nextLeagueName(league)}» $toNext',
          style: AppFonts.mono(fontSize: 9, color: AppColors.muted),
        ),
        if (rating.isProvisional) ...[
          const SizedBox(height: 4),
          Text(
            'Первые ${PlayerRating.calibrationMatches} матчей рейтинг ходит '
            'вдвое быстрее обычного — так он быстрее придёт к твоему уровню.',
            textAlign: TextAlign.center,
            style: AppFonts.ui(fontSize: 10, color: AppColors.muted),
          ),
        ],
      ],
    );
  }

  static String _nextLeagueName(League current) {
    final i = leagueBands.indexOf(current);
    return (i >= 0 && i + 1 < leagueBands.length)
        ? leagueBands[i + 1].name
        : leagueBands.last.name;
  }
}

class _Stat {
  final String value;
  final String label;
  final Color color;

  const _Stat({required this.value, required this.label, required this.color});
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
              'Пробный период закончился — режимы с ИИ закрыты, Тренировка доступна',
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

