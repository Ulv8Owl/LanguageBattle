import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/game_access.dart';
import '../../core/leagues.dart';
import '../../core/nav_state.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../widgets/chrolingo_widgets.dart';
import '../../widgets/trial_countdown_banner.dart';

const _languageFlags = {'en': '🇬🇧', 'es': '🇪🇸', 'ru': '🇷🇺'};

/// Максимум языковых пар на аккаунт (задача итерации). С сегодняшними
/// тремя поддерживаемыми языками (en/es/ru) реально достижимо не больше
/// 2 пар одновременно — родной язык занимает один слот, а третий язык
/// пока просто не существует. Ограничение честно фиксируется здесь и
/// проверяется на сервере (`add_language_pair`), а не только в UI.
const kMaxLanguagePairs = 4;

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _profile;

  /// Все изучаемые языки аккаунта (до kMaxLanguagePairs), каждый со своим
  /// ELO. Ровно один помечен is_active — он используется везде в
  /// приложении (Арена, бой, матчмейкинг, Тренировка).
  List<Map<String, dynamic>> _pairs = [];
  WalletState _wallet = WalletState.empty;
  int _played = 0;
  int _winPct = 0;
  int _streak = 0;
  List<Map<String, dynamic>> _inventory = [];
  bool _loading = true;
  bool _switchingPair = false;

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
      final pairs = await supabase
          .from('user_languages')
          .select()
          .eq('user_id', uid)
          .eq('role', 'learning')
          .order('language_code');
      final asA = await supabase.from('matches').select().eq('player_a_id', uid).eq('status', 'completed');
      final asB = await supabase.from('matches').select().eq('player_b_id', uid).eq('status', 'completed');
      final all = [...asA, ...asB]
        ..sort((a, b) => (b['completed_at'] as String? ?? '').compareTo(a['completed_at'] as String? ?? ''));

      final played = all.length;
      final wins = all.where((m) => m['winner_id'] == uid).length;
      var streak = 0;
      for (final m in all) {
        if (m['winner_id'] == uid) {
          streak++;
        } else {
          break;
        }
      }

      final inventory = await supabase
          .from('user_inventory')
          .select('item_id, cosmetic_items(*)')
          .eq('user_id', uid);
      // sync_wallet заодно отдаёт актуальный статус подписки — нужен для
      // плашки пробного периода (задача итерации, п.5: плашка переехала
      // сюда из Арены).
      final wallet = await GameAccess.sync();

      if (!mounted) return;
      setState(() {
        _profile = profile;
        _pairs = List<Map<String, dynamic>>.from(pairs);
        _wallet = wallet;
        _played = played;
        _winPct = played == 0 ? 0 : ((wins / played) * 100).round();
        _streak = streak;
        _inventory = List<Map<String, dynamic>>.from(inventory);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Переключает активную пару. Рейтинг НЕ трогается ни у старой, ни у
  /// новой пары — это просто смена того, какая строка сейчас "активна"
  /// (задача итерации: "рейтинг НЕ обнуляется, а записывается для новой
  /// пары... выбрав старую пару рейтинг опять отображается").
  Future<void> _selectPair(String targetLanguage) async {
    setState(() => _switchingPair = true);
    try {
      await supabase.rpc('set_active_language_pair', params: {'p_target_language': targetLanguage});
      notifyLanguagePairChanged();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось переключить пару: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _switchingPair = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final username = (_profile?['username'] as String?) ?? 'Игрок';
    final native = (_profile?['native_language'] as String?) ?? '?';
    final activePair = _pairs.cast<Map<String, dynamic>?>().firstWhere(
          (p) => p?['is_active'] == true,
          orElse: () => null,
        );
    final elo = (activePair?['elo'] as int?) ?? 1000;
    final league = leagueFor(elo);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              ChAvatar(name: username, size: 58, ringColor: league.color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(username, style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.emoji_events, size: 14, color: league.color),
                        const SizedBox(width: 5),
                        Text(
                          '${league.shortName} · $elo ELO',
                          style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: league.color),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Профиль — единственная точка входа в редактор аватара и в
              // Настройки (раздел 5.1, п.7): отдельного пункта нижней
              // навигации для настроек нет.
              IconButton(
                tooltip: 'Редактор аватара',
                onPressed: () async {
                  await context.push('/avatar');
                  if (mounted) _load();
                },
                icon: const Icon(Icons.face_retouching_natural, size: 22, color: AppColors.gold),
              ),
              IconButton(
                tooltip: 'Настройки',
                onPressed: () => context.push('/settings'),
                icon: const Icon(Icons.settings, size: 22, color: AppColors.muted),
              ),
            ],
          ),
          if (_wallet.isTrial && _wallet.trialEndsAt != null) ...[
            const SizedBox(height: 16),
            TrialCountdownBanner(trialEndsAt: _wallet.trialEndsAt!),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _StatTile(value: '$_played', label: 'боёв')),
              const SizedBox(width: 8),
              Expanded(child: _StatTile(value: '$_winPct%', label: 'побед', color: AppColors.cyan)),
              const SizedBox(width: 8),
              Expanded(child: _StatTile(value: '🔥$_streak', label: 'серия', color: AppColors.ember)),
            ],
          ),
          const SizedBox(height: 18),
          Text('ЯЗЫКОВЫЕ ПАРЫ', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 8),
          Opacity(
            opacity: _switchingPair ? 0.5 : 1,
            child: IgnorePointer(
              ignoring: _switchingPair,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final pair in _pairs)
                    _LanguagePairChip(
                      nativeFlag: _languageFlags[native] ?? '🏳',
                      targetFlag: _languageFlags[pair['language_code'] as String?] ?? '🏳',
                      active: pair['is_active'] == true,
                      onTap: pair['is_active'] == true
                          ? null
                          : () => _selectPair(pair['language_code'] as String),
                    ),
                  if (_pairs.length < kMaxLanguagePairs)
                    _AddPairChip(
                      onTap: () async {
                        await context.push('/language-pair');
                        if (mounted) _load();
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text('ИНВЕНТАРЬ', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 8),
          if (_inventory.isEmpty)
            const Text('Пока пусто — загляните в Магазин.', style: TextStyle(color: AppColors.muted, fontSize: 12))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _inventory.map((row) {
                final item = row['cosmetic_items'] as Map<String, dynamic>?;
                final equipped = item?['id'] == _profile?['equipped_frame_id'] || item?['id'] == _profile?['equipped_emote_id'];
                return Container(
                  width: 64,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: equipped ? AppColors.gold : AppColors.line),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        item?['type'] == 'emote' ? Icons.emoji_emotions : Icons.circle_outlined,
                        color: AppColors.gold,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        (item?['name'] as String?) ?? '',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 8, color: AppColors.muted),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}

/// Плашка языковой пары — размером под сами флаги, не растянута на всю
/// ширину (задача итерации: "не была сильно длиннее чем сам текст").
/// Активная пара подсвечена золотом.
class _LanguagePairChip extends StatelessWidget {
  final String nativeFlag;
  final String targetFlag;
  final bool active;
  final VoidCallback? onTap;

  const _LanguagePairChip({
    required this.nativeFlag,
    required this.targetFlag,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: active ? AppColors.goldSoft : AppColors.navy3,
          border: Border.all(color: active ? AppColors.gold : AppColors.line, width: active ? 1.5 : 1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('$nativeFlag → $targetFlag', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// Плашка «+» той же формы и размера, что и обычная пара — появляется
/// справа от последней, пока пар меньше kMaxLanguagePairs.
class _AddPairChip extends StatelessWidget {
  final VoidCallback onTap;

  const _AddPairChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.navy3,
          border: Border.all(color: AppColors.lineStrong, style: BorderStyle.solid),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.add, size: 16, color: AppColors.muted),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _StatTile({required this.value, required this.label, this.color = AppColors.cream});

  @override
  Widget build(BuildContext context) {
    return ChPanel(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Column(
        children: [
          Text(value, style: AppFonts.mono(fontSize: 15, weight: FontWeight.w700, color: color)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 8, color: AppColors.muted)),
        ],
      ),
    );
  }
}
