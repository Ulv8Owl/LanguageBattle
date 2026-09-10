import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/services.dart';

import '../../core/app_events.dart';
import '../../core/app_locale.dart';
import '../../core/debug_flags.dart';
import '../../core/leagues.dart';
import '../../core/supabase_client.dart';
import '../../data/judge_models.dart';
import '../../data/player_rating.dart';
import '../../data/training_session.dart';
import '../../core/theme.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Настройки (раздел 5.1, п.7 и 5.3). Вход только через Профиль — отдельного
/// пункта в нижней навигации для настроек нет.
///
/// Экран намеренно минимальный: язык интерфейса, уведомления, приватность,
/// блокировка/жалобы. Реальная локализация интерфейса, push-уведомления и
/// экран модерации — отдельные задачи (разделы 7 и 8 спеки, Фазы 5-6),
/// поэтому переключатели здесь честно помечены как ещё не подключённые,
/// а не притворяются рабочими.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notifications = true;
  bool _hideFromLeaderboard = false;

  /// Родные языки игрока (до 6, миграция 0025). Ровно один помечен
  /// primary — тот, что раньше был единственным «родным языком» — и он
  /// всегда равен users.native_language: эту связь держит сервер (триггер
  /// + RPC ниже), здесь список только показывается и правится через RPC.

  /// Сколько карточек выдаётся за одну тренировку.
  int _deckSize = defaultTrainingDeckSize;
  bool _savingDeckSize = false;

  /// Рейтинг по изучаемому языку. Здесь его можно задать вручную — это
  /// отладочная возможность: дождаться перехода в следующую лигу честной
  /// игрой это десятки матчей, а проверять надо все шесть.
  PlayerRating? _rating;
  bool _savingRating = false;

  /// Модели разбора. Ветка LLM существует ради сравнения цены и качества, и
  /// переключатели — единственный способ это сравнение провести: сменить
  /// модель между двумя ответами подряд на одной и той же фразе.
  String _asrModel = defaultAsrModel;
  String _llmModel = defaultLlmModel;
  bool _savingModels = false;

  /// Пока идёт удаление, кнопку нельзя нажать второй раз: повторный вызов
  /// delete_account после успешного первого упрётся в «not authenticated».
  bool _deletingAccount = false;

  @override
  void initState() {
    super.initState();
    _loadNativeLanguage();
    _loadJudgeModels();
  }

  Future<void> _loadNativeLanguage() async {
    try {
      final row = await supabase
          .from('users')
          .select('training_deck_size')
          .eq('id', currentUserId)
          .maybeSingle();
      if (!mounted) return;
      final learning = await supabase
          .from('user_languages')
          .select(PlayerRating.columns)
          .eq('user_id', currentUserId)
          .eq('role', 'learning')
          .eq('is_active', true)
          .limit(1)
          .maybeSingle();
      setState(() {
        final size = (row?['training_deck_size'] as num?)?.toInt();
        if (size != null && trainingDeckSizes.contains(size)) _deckSize = size;
        _rating = learning == null ? null : PlayerRating.fromRow(learning);
      });
    } catch (_) {
      // Не удалось — покажем прочерк, менять язык это не мешает.
    }
  }

  Future<void> _signOut() async {
    await supabase.auth.signOut();
    if (mounted) context.go('/login');
  }

  /// Выбор языка интерфейса. Языки подписаны на самих себе (Русский /
  /// English), а не переведены на текущий язык: игрок, случайно
  /// переключившийся на незнакомый язык, должен суметь найти свой обратно.
  Future<void> _pickInterfaceLanguage() async {
    final t = AppLocale.strings;
    final picked = await showModalBottomSheet<String>(
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
            Text(t.interfaceLanguage,
                style: AppFonts.ui(fontSize: 15, weight: FontWeight.w800)),
            const SizedBox(height: 8),
            for (final code in AppLocale.supported)
              ListTile(
                title: Text(AppLocale.endonyms[code] ?? code),
                trailing: code == AppLocale.code.value
                    ? const Icon(Icons.check, color: AppColors.gold, size: 20)
                    : null,
                onTap: () => Navigator.of(ctx).pop(code),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await AppLocale.set(picked);
    // Приложение перерисуется целиком по ValueNotifier в LanguageBattleApp;
    // setState нужен, чтобы обновился и этот экран, если он уже построен.
    if (mounted) setState(() {});
  }

  /// Удаление аккаунта. Пока «для тестирования», но сделано по-настоящему:
  /// RPC delete_account (миграция 0027) сносит строку auth.users, и всё
  /// остальное уходит каскадом. Мягкого удаления и корзины нет — если они
  /// понадобятся, это отдельное решение, а не молчаливая заглушка здесь.
  Future<void> _deleteAccount() async {
    final t = AppLocale.strings;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.navy2,
        title: Text(t.deleteAccountConfirmTitle),
        content: Text(
          t.deleteAccountConfirmBody,
          style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.deleteAccountConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingAccount = true);
    try {
      await supabase.rpc('delete_account');
      // Сессия указывает на удалённого пользователя — выходим из неё, иначе
      // следующий запрос упрётся в чужой (уже несуществующий) uid.
      await supabase.auth.signOut();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.deleteAccountDone)),
      );
      context.go('/login');
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletingAccount = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.deleteAccountFailed(e))),
      );
    }
  }

  void _notReadyYet(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what появится в следующей итерации')),
    );
  }

  Future<void> _loadJudgeModels() async {
    try {
      final models = await fetchJudgeModels();
      if (!mounted) return;
      setState(() {
        _asrModel = models.asr;
        _llmModel = models.llm;
      });
    } catch (_) {
      // Молча: не прочитался выбор — покажем модели по умолчанию, те же,
      // что подставит сервер. Ошибка здесь ничего не ломает.
    }
  }

  /// Один список — один выбор. Оба переключателя устроены одинаково, потому
  /// что это один и тот же выбор в двух местах: две копии этого кода
  /// разъехались бы на первой же правке.
  Future<void> _pickModel({
    required String title,
    required String note,
    required List<String> options,
    required String current,
    required Future<void> Function(String) save,
    required void Function(String) apply,
  }) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.navy2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Text(title,
                style: AppFonts.ui(fontSize: 15, weight: FontWeight.w800, color: AppColors.cream)),
            const SizedBox(height: 4),
            Text(
              note,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final model in options)
                    ListTile(
                      title:
                          Text(model, style: AppFonts.mono(fontSize: 12, color: AppColors.cream)),
                      trailing: model == current
                          ? const Icon(Icons.check, color: AppColors.gold)
                          : null,
                      onTap: () => Navigator.of(ctx).pop(model),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked == null || picked == current || !mounted) return;

    setState(() => _savingModels = true);
    try {
      await save(picked);
      if (!mounted) return;
      setState(() {
        apply(picked);
        _savingModels = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingModels = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $e')),
      );
    }
  }

  Future<void> _pickDeckSize() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.navy2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Text('Карточек за тренировку',
                style: AppFonts.ui(fontSize: 15, weight: FontWeight.w800, color: AppColors.cream)),
            const SizedBox(height: 4),
            const Text(
              'В колоде 100 карточек. За один заход выдаётся столько,\nследующий заход продолжит с того же места.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 8),
            for (final size in trainingDeckSizes)
              ListTile(
                title: Text('$size'),
                trailing: size == _deckSize ? const Icon(Icons.check, color: AppColors.gold) : null,
                onTap: () => Navigator.of(ctx).pop(size),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked == null || picked == _deckSize || !mounted) return;

    setState(() => _savingDeckSize = true);
    try {
      await supabase
          .from('users')
          .update({'training_deck_size': picked})
          .eq('id', currentUserId);
      if (!mounted) return;
      setState(() {
        _deckSize = picked;
        _savingDeckSize = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingDeckSize = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $e')),
      );
    }
  }

  /// На Эло правится одно число: рейтинг, он же лига, он же сложность
  /// фраз. На Glicko-2 здесь было два поля (рейтинг в зачёт лиги и
  /// отклонение), потому что выставить «рейтинг 2400» и увидеть у себя
  /// Алмаз было нельзя — лига считалась на два отклонения ниже.
  ///
  /// Второе поле — сыгранные матчи: от них зависит цена матча K и пометка
  /// «рейтинг ещё уточняется», и проверить оба состояния (новичок / уже
  /// откалиброван) иначе нечем.
  Future<void> _editRating() async {
    final current = _rating ?? PlayerRating.newcomer;
    final ratingController =
        TextEditingController(text: '${current.display}');
    final matchesController =
        TextEditingController(text: '${current.matchesPlayed}');
    final entered = await showDialog<List<int>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.navy2,
        title: const Text('Рейтинг'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Отладочная настройка. Рейтинг Эло — он же лига, он же '
              'сложность фраз и доступные наборы слов: одно число, пороги '
              'лиг ниже даны в нём же.',
              style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ratingController,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Рейтинг'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: matchesController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Сыграно матчей: <10 — рейтинг предварительный',
              ),
            ),
            const SizedBox(height: 10),
            for (final band in leagueBands)
              Text(
                '${band.titleWithLevel}: от ${band.min}'
                '${band.max > 90000 ? '' : ' до ${band.max - 1}'}',
                style: AppFonts.mono(fontSize: 10, color: band.color),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          TextButton(
            onPressed: () {
              final value = int.tryParse(ratingController.text.trim());
              final matches = int.tryParse(matchesController.text.trim());
              Navigator.of(ctx).pop(
                value == null || matches == null ? null : [value, matches],
              );
            },
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    if (entered == null || !mounted) return;
    // Нижняя граница 0 — та же, что в базе: sync_rating_mirrors не даёт
    // рейтингу уйти в минус, и отладка не должна показывать то, чего
    // в игре быть не может.
    final value = entered[0].clamp(0, 99999);
    final matches = entered[1].clamp(0, 9999);

    setState(() => _savingRating = true);
    try {
      // elo, league_rating, league и cefr_level пересчитает триггер
      // trg_sync_rating_mirrors — их отсюда трогать нельзя.
      await supabase
          .from('user_languages')
          .update({
            'rating': value.toDouble(),
            'matches_played': matches,
            'rating_updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('user_id', currentUserId)
          .eq('role', 'learning')
          .eq('is_active', true);
      if (!mounted) return;
      setState(() {
        _rating = PlayerRating(
          rating: value.toDouble(),
          leagueRating: value,
          matchesPlayed: matches,
        );
        _savingRating = false;
      });
      // Арена держит рейтинг в своём состоянии и сама его не перечитывает.
      notifyProfileChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Рейтинг $value · ${leagueFor(value).titleWithLevel} '
              '· матчей $matches'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingRating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось изменить рейтинг: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocale.strings;
    return Scaffold(
      appBar: AppBar(title: Text(t.settingsTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(t.sectionInterface, style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _Row(
                    icon: Icons.language,
                    title: t.interfaceLanguage,
                    trailing: Text(
                      AppLocale.endonyms[AppLocale.code.value] ?? AppLocale.code.value,
                      style: AppFonts.mono(fontSize: 11, color: AppColors.muted),
                    ),
                    onTap: _pickInterfaceLanguage,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(t.sectionTraining, style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: _Row(
                icon: Icons.style,
                title: t.cardsPerTraining,
                trailing: _savingDeckSize
                    ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('$_deckSize', style: AppFonts.mono(fontSize: 11, color: AppColors.muted)),
                onTap: _savingDeckSize ? null : _pickDeckSize,
              ),
            ),
            const SizedBox(height: 18),
            Text(t.sectionDebug, style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.danger)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _Row(
                    icon: Icons.record_voice_over_outlined,
                    title: 'Распознавание речи',
                    trailing: _savingModels
                        ? const SizedBox(
                            height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_asrModel,
                            style: AppFonts.mono(fontSize: 9, color: AppColors.muted)),
                    onTap: _savingModels
                        ? null
                        : () => _pickModel(
                              title: 'Распознавание речи',
                              note: 'Первый шаг: превращает запись в текст.\n'
                                  'За аудио платит только он.',
                              options: asrModels,
                              current: _asrModel,
                              save: saveAsrModel,
                              apply: (m) => _asrModel = m,
                            ),
                  ),
                  const Divider(height: 1, color: AppColors.line),
                  _Row(
                    icon: Icons.psychology_outlined,
                    title: 'Судья по тексту',
                    trailing: _savingModels
                        ? const SizedBox(
                            height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_llmModel,
                            style: AppFonts.mono(fontSize: 9, color: AppColors.muted)),
                    onTap: _savingModels
                        ? null
                        : () => _pickModel(
                              title: 'Судья по тексту',
                              note: 'Второй шаг: ищет ошибки в расшифровке.\n'
                                  'Записи не слышит — только текст.',
                              options: llmModels,
                              current: _llmModel,
                              save: saveLlmModel,
                              apply: (m) => _llmModel = m,
                            ),
                  ),
                  const Divider(height: 1, color: AppColors.line),
                  _Row(
                    icon: Icons.emoji_events_outlined,
                    title: t.ratingAndLeague,
                    trailing: _savingRating
                        ? const SizedBox(
                            height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(
                            _rating == null
                                ? '—'
                                : '${_rating!.display} · ${_rating!.league.cefr}',
                            style: AppFonts.mono(fontSize: 11, color: AppColors.muted),
                          ),
                    onTap: _savingRating ? null : _editRating,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(t.sectionNotifications, style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: _Row(
                icon: Icons.notifications_none,
                title: t.matchNotifications,
                trailing: Switch(
                  value: _notifications,
                  activeThumbColor: AppColors.gold,
                  onChanged: (v) {
                    setState(() => _notifications = v);
                    _notReadyYet('Push-уведомления');
                  },
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(t.sectionPrivacy, style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _Row(
                    icon: Icons.visibility_off_outlined,
                    title: t.hideFromLeaderboard,
                    trailing: Switch(
                      value: _hideFromLeaderboard,
                      activeThumbColor: AppColors.gold,
                      onChanged: (v) {
                        setState(() => _hideFromLeaderboard = v);
                        _notReadyYet('Скрытие из рейтинга');
                      },
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.line),
                  _Row(
                    icon: Icons.block,
                    title: t.blockedPlayers,
                    onTap: () => _notReadyYet('Список блокировок'),
                  ),
                  const Divider(height: 1, color: AppColors.line),
                  _Row(
                    icon: Icons.flag_outlined,
                    title: t.myReports,
                    onTap: () => _notReadyYet('История жалоб'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(t.sectionAbout, style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: _Row(
                icon: Icons.info_outline,
                title: t.buildVersion,
                // Метка коммита, вшитая при сборке (--dart-define=BUILD_ID).
                // Живёт здесь, а не на игровых экранах: спрашивают её редко,
                // но когда спрашивают — ответ нужен точный, и «какой у тебя
                // билд» иначе выясняется сравнением скриншотов с историей git.
                trailing: Text(
                  kBuildId,
                  style: AppFonts.mono(fontSize: 11, color: AppColors.muted),
                ),
                // Скопировать удобнее, чем переписывать семь символов с экрана.
                onTap: () {
                  Clipboard.setData(ClipboardData(text: kBuildParts.join(' · ')));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(t.versionCopied)),
                  );
                },
              ),
            ),
            const SizedBox(height: 18),
            Text(t.sectionAccount, style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.danger)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: _Row(
                icon: Icons.delete_forever_outlined,
                title: t.deleteAccount,
                trailing: _deletingAccount
                    ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.chevron_right, color: AppColors.danger, size: 20),
                onTap: _deletingAccount ? null : _deleteAccount,
              ),
            ),
            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: const BorderSide(color: AppColors.lineStrong),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _signOut,
                child: Text(t.signOut),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;

  final Widget? trailing;
  final VoidCallback? onTap;

  const _Row({required this.icon, required this.title, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppColors.muted),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: AppFonts.ui(fontSize: 13))),
            trailing ?? const Icon(Icons.chevron_right, color: AppColors.muted, size: 20),
          ],
        ),
      ),
    );
  }
}
