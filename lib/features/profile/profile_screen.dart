import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/all_languages.dart';
import '../../core/game_access.dart';
import '../../core/nav_state.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/achievements.dart';
import '../../data/language_pairs.dart';
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

  /// Все пары аккаунта, каждая со своим рейтингом. Ровно одна активна — ей
  /// пользуются все режимы (Арена, бой, матчмейкинг, Тренировка).
  List<LanguagePair> _pairs = [];
  WalletState _wallet = WalletState.empty;
  int _played = 0;
  int _winPct = 0;
  int _streak = 0;
  /// По одной плашке на вид достижения: полученная или серая (см.
  /// AchievementSlot).
  List<AchievementSlot> _achievements = const [];
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
      // Скрытые плашки не показываем, но и не удаляем: hidden_at убирает
      // пару с экрана, оставляя рейтинг, лигу и историю целыми
      // (миграция 0034).
      final pairs = await fetchLanguagePairs(uid);
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
        _pairs = pairs;
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

  Widget _pairChip(LanguagePair pair) {
    return _LanguagePairChip(
      nativeFlag: languageFlag(pair.speaks),
      targetFlag: languageFlag(pair.learns),
      nativeName: languageName(pair.speaks),
      targetName: languageName(pair.learns),
      // Подсвечена ВЫБРАННАЯ пара, а не та, по которой сейчас попали
      // пальцем. Подсветка означает «этой парой вы играете», и мигать ею
      // на каждом касании значило бы обесценить единственный признак, по
      // которому активную пару вообще видно.
      active: pair.isActive,
      onTap: () => _openPairMenu(pair),
    );
  }

  /// Меню плашки: выбрать пару или убрать её с профиля.
  ///
  /// ПОЧЕМУ МЕНЮ, А НЕ ПРЯМОЕ ПЕРЕКЛЮЧЕНИЕ. Тап по плашке раньше сразу
  /// менял активную пару. Промах по соседней плашке молча уводил игрока на
  /// другой язык, и заметно это становилось уже в бою. Лишний шаг здесь
  /// стоит секунды и убирает целый класс случайных переключений.
  ///
  /// Тап мимо листа закрывает его, ничего не меняя, — это поведение
  /// showModalBottomSheet по умолчанию, и оно ровно то, что нужно: отмена
  /// должна быть самым доступным действием.
  Future<void> _openPairMenu(LanguagePair pair) async {
    final isActive = pair.isActive;
    final title = '${languageFlag(pair.speaks)} ${languageName(pair.speaks)} → '
        '${languageFlag(pair.learns)} ${languageName(pair.learns)}';

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.navy2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text(title, style: AppFonts.ui(fontSize: 15, weight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              isActive ? 'Сейчас выбрана' : 'Не выбрана',
              style: AppFonts.mono(fontSize: 10, color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.check_circle_outline, color: AppColors.gold),
              title: const Text('Выбрать языковую пару'),
              enabled: !isActive,
              onTap: () => Navigator.pop(ctx, 'select'),
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined, color: AppColors.danger),
              title: const Text('Удалить языковую пару'),
              subtitle: Text(
                isActive
                    ? 'Сначала выберите другую пару'
                    : 'Плашка исчезнет с профиля. Рейтинг, лига и история '
                        'по этой паре сохранятся — добавите её снова, и всё вернётся.',
                style: AppFonts.ui(fontSize: 11, color: AppColors.muted),
              ),
              isThreeLine: !isActive,
              enabled: !isActive,
              onTap: () => Navigator.pop(ctx, 'hide'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (action == 'select') await _selectPair(pair);
    if (action == 'hide') await _hidePair(pair);
  }

  /// Убирает плашку с профиля, не трогая саму пару.
  Future<void> _hidePair(LanguagePair pair) async {
    setState(() => _switchingPair = true);
    try {
      await hideLanguagePair(speaks: pair.speaks, learns: pair.learns);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось убрать пару: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _switchingPair = false);
    }
  }

  Widget _addPairChip() => _AddPairChip(
        onTap: () async {
          await context.push('/language-pair');
          if (mounted) _load();
        },
      );

  /// Пары языков — один список сверху вниз, «плюс» всегда последним.
  ///
  /// РАНЬШЕ ОНИ ГРУППИРОВАЛИСЬ ПО РОДНОМУ ЯЗЫКУ, а «плюс» стоял в конце
  /// ряда — то есть у одной пары оказывался справа от неё, а у пяти уезжал
  /// куда-то в середину экрана. Группы держались на реестре родных языков,
  /// которого больше нет: пара — это просто два языка, и делить их не по
  /// чему. Один столбец, и кнопка всегда там, где её ждут.
  Widget _buildPairs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final pair in _pairs) ...[
          _pairChip(pair),
          const SizedBox(height: 8),
        ],
        _addPairChip(),
      ],
    );
  }

  /// Переключает активную пару. Рейтинг НЕ трогается ни у старой, ни у
  /// новой пары — это просто смена того, какая строка сейчас "активна"
  /// (задача итерации: "рейтинг НЕ обнуляется, а записывается для новой
  /// пары... выбрав старую пару рейтинг опять отображается").
  Future<void> _selectPair(LanguagePair pair) async {
    setState(() => _switchingPair = true);
    try {
      // Пара адресуется ОБОИМИ языками: с двух разных языков можно учить
      // один и тот же (ru→es и en→es), и по одному изучаемому она не
      // опознаётся.
      await setActiveLanguagePair(speaks: pair.speaks, learns: pair.learns);
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
    // Рейтинг показывается по АКТИВНОЙ паре: у каждой он свой, и «рейтинг
    // аккаунта» — величина, которой не существует.
    final active = _pairs.where((p) => p.isActive).firstOrNull ?? _pairs.firstOrNull;
    final rating = active?.rating ?? PlayerRating.newcomer;
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
          Text('ЯЗЫКОВЫЕ ПАРЫ', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 8),
          Opacity(
            opacity: _switchingPair ? 0.5 : 1,
            child: IgnorePointer(
              ignoring: _switchingPair,
              child: _buildPairs(),
            ),
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

/// Плашка языковой пары — размером под сами флаги, не растянута на всю
/// ширину (задача итерации: "не была сильно длиннее чем сам текст").
/// Активная пара подсвечена золотом.
class _LanguagePairChip extends StatelessWidget {
  final String nativeFlag;
  final String targetFlag;

  /// Названия языков рядом с флагами: одни флаги игрок читает как ребус, а
  /// пар теперь может быть сколько угодно, и «🇷🇺 → 🇬🇧» среди шести таких
  /// же строк не отличить.
  final String nativeName;
  final String targetName;
  final bool active;
  final VoidCallback? onTap;

  const _LanguagePairChip({
    required this.nativeFlag,
    required this.targetFlag,
    required this.nativeName,
    required this.targetName,
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
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$nativeFlag $nativeName  →  $targetFlag $targetName',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            if (active)
              Text('выбрана',
                  style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          ],
        ),
      ),
    );
  }
}

/// Плашка «+» той же формы и размера, что и обычная пара — появляется
/// последней строкой списка — там, где её и ищут.
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
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 16, color: AppColors.muted),
            SizedBox(width: 8),
            Text('Добавить пару', style: TextStyle(color: AppColors.muted, fontSize: 13)),
          ],
        ),
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
