import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/game_access.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/achievements.dart';
import '../../data/my_languages.dart';
import '../../data/player_rating.dart';
import '../../data/avatar_parts.dart';
import '../../widgets/avatar_portrait.dart';
import '../../widgets/chrolingo_widgets.dart';
import '../../widgets/trial_countdown_banner.dart';


class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _profile;

  /// Языки игрока: на каком говорит и какой учит. Весь прогресс — рейтинг,
  /// лига, монеты, опыт, достижения — принадлежит ИЗУЧАЕМОМУ языку
  /// (миграция 0051), поэтому и рейтинг здесь берётся отсюда.
  ///
  /// ВЫБИРАЮТ ЯЗЫКИ В НАСТРОЙКАХ, А НЕ ЗДЕСЬ. Профиль показывает, чего
  /// игрок добился; смена языка — это настройка, и раньше она стояла
  /// посреди достижений, где её случайно и нажимали.
  MyLanguages? _languages;
  WalletState _wallet = WalletState.empty;
  int _played = 0;
  int _winPct = 0;
  int _streak = 0;
  /// По одной плашке на вид достижения: полученная или серая (см.
  /// AchievementSlot).
  List<AchievementSlot> _achievements = const [];
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
      final languages = await fetchMyLanguages(uid);
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

      final achievements = await loadAchievements(uid);
      // sync_wallet заодно отдаёт актуальный статус подписки — нужен для
      // плашки пробного периода (задача итерации, п.5: плашка переехала
      // сюда из Арены).
      final wallet = await GameAccess.sync();

      if (!mounted) return;
      setState(() {
        _profile = profile;
        _languages = languages;
        _wallet = wallet;
        _played = played;
        _winPct = played == 0 ? 0 : ((wins / played) * 100).round();
        _streak = streak;
        _achievements = achievements;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Что это за достижение. У полученного — описание, у серого — как его
  /// получить: иначе серая плашка была бы загадкой без подсказки.
  void _showAchievement(AchievementSlot slot) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.navy2,
        title: Text(
          slot.kind.title,
          style: AppFonts.ui(
            fontSize: 16,
            weight: FontWeight.w800,
            color: slot.earned ? AppColors.gold : AppColors.muted,
          ),
        ),
        content: Text(slot.detail, style: const TextStyle(height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final username = (_profile?['username'] as String?) ?? 'Игрок';
    // Рейтинг показывается по ИЗУЧАЕМОМУ языку: у каждого он свой, и
    // «рейтинг аккаунта» — величина, которой не существует.
    final rating = _languages?.rating ?? PlayerRating.newcomer;
    final league = rating.league;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              // Аватар — он же кнопка редактора. Отдельной иконки для
              // этого больше нет: собранный портрет и есть то, на что
              // хочется нажать, а иконка рядом только спрашивала «а это
              // тогда что?».
              AvatarButton(
                name: username,
                avatar: avatarFromJson(_profile?['equipped_avatar']),
                // Своя аватарка всегда золотая — см. тот же довод на Арене.
                ringColor: AppColors.gold,
                onDone: _load,
              ),
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
                          '${league.shortName} · ${rating.display} рейтинга',
                          style: AppFonts.mono(fontSize: 10, weight: FontWeight.w700, color: league.color),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Настройки открываются отсюда: отдельного пункта нижней
              // навигации для них нет (раздел 5.1, п.7).
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
          // ИНВЕНТАРЯ ЗДЕСЬ БОЛЬШЕ НЕТ. Он показывал купленные предметы —
          // то же самое, что уже видно в Магазине и на самом аватаре, — а
          // место занимал то, где игроку интереснее видеть, чего он добился.
          Text('ДОСТИЖЕНИЯ', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final slot in _achievements)
                _AchievementBadge(
                  slot: slot,
                  onTap: () => _showAchievement(slot),
                ),
            ],
          ),
        ],
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

/// Плашка достижения. Полученная — золотая, ещё не полученная — серая, той
/// же формы.
///
/// СЕРАЯ ИМЕННО ВЫРЕЗАНА, а не затемнена: форма и обводка те же, что у
/// полученной, а внутри ровно серый цвет. Так видно, что место под
/// достижение есть и оно ждёт, а не что картинка не загрузилась.
class _AchievementBadge extends StatelessWidget {
  final AchievementSlot slot;
  final VoidCallback onTap;

  const _AchievementBadge({required this.slot, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final earned = slot.earned;
    final color = earned ? AppColors.gold : AppColors.muted;
    final tier = slot.earnedTier ?? slot.nextTier;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 82,
        child: Column(
          children: [
            Container(
              height: 58,
              width: 58,
              decoration: BoxDecoration(
                color: earned ? AppColors.gold.withValues(alpha: 0.12) : AppColors.navy3,
                border: Border.all(color: earned ? AppColors.gold : AppColors.lineStrong, width: 2),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.local_fire_department, size: 22, color: color),
                    Text(
                      '$tier',
                      style: AppFonts.mono(fontSize: 11, weight: FontWeight.w800, color: color),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              slot.kind.title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.mono(fontSize: 8, weight: FontWeight.w700, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
