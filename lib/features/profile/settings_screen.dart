import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/services.dart';

import '../../core/all_languages.dart';
import '../../core/app_events.dart';
import '../../core/debug_flags.dart';
import '../../core/leagues.dart';
import '../../core/supabase_client.dart';
import '../../data/native_languages.dart';
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
  List<NativeLanguage> _natives = [];

  /// Сколько карточек выдаётся за одну тренировку.
  int _deckSize = defaultTrainingDeckSize;
  bool _savingDeckSize = false;

  /// Рейтинг по изучаемому языку. Здесь его можно задать вручную — это
  /// отладочная возможность: дождаться перехода в следующую лигу честной
  /// игрой это десятки матчей, а проверять надо все шесть.
  PlayerRating? _rating;
  bool _savingRating = false;

  @override
  void initState() {
    super.initState();
    _loadNativeLanguage();
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
      final natives = await NativeLanguages.fetch(currentUserId);
      if (!mounted) return;
      setState(() {
        _natives = natives;
        final size = (row?['training_deck_size'] as num?)?.toInt();
        if (size != null && trainingDeckSizes.contains(size)) _deckSize = size;
        _rating = learning == null ? null : PlayerRating.fromRow(learning);
      });
    } catch (_) {
      // Не удалось — покажем прочерк, менять язык это не мешает.
    }
  }

  /// Список родных языков — просмотр, назначение главного, удаление,
  /// добавление нового. Полиглот может знать до шести языков (миграция
  /// 0025); главный (звезда) — это то же самое, что раньше было
  /// единственным «родным языком», и по-прежнему решает, на каком языке
  /// показываются задания там, где у пары ещё нет своего anchor'а.
  Future<void> _manageNativeLanguages() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.navy2,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> refresh() async {
            final natives = await NativeLanguages.fetch(currentUserId);
            if (mounted) setState(() => _natives = natives);
            setSheetState(() {});
          }

          Future<void> makePrimary(String code) async {
            try {
              await NativeLanguages.setPrimary(code);
              await refresh();
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('Не удалось сделать главным: $e')));
              }
            }
          }

          Future<void> remove(String code) async {
            try {
              await NativeLanguages.remove(code);
              await refresh();
            } catch (e) {
              final msg = e.toString().contains('must_keep_one_native')
                  ? 'Нужен хотя бы один родной язык — сначала добавь другой.'
                  : 'Не удалось удалить: $e';
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
            }
          }

          Future<void> addNew() async {
            final existing = _natives.map((n) => n.code).toSet();
            final picked = await _pickFromAllLanguages(exclude: existing);
            if (picked == null) return;
            try {
              await NativeLanguages.add(picked);
              await refresh();
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось добавить: $e')));
              }
            }
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 16),
                  Text('Родные языки',
                      style: AppFonts.ui(fontSize: 15, weight: FontWeight.w800, color: AppColors.cream)),
                  const SizedBox(height: 4),
                  const Text(
                    'Звезда — главный: на нём показываются задания, если у пары ещё нет своего.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.3),
                  ),
                  const SizedBox(height: 8),
                  for (final native in _natives)
                    ListTile(
                      title: Text(allLanguages[native.code]?.endonym ?? native.code),
                      leading: IconButton(
                        icon: Icon(
                          native.isPrimary ? Icons.star : Icons.star_border,
                          color: native.isPrimary ? AppColors.gold : AppColors.muted,
                        ),
                        onPressed: native.isPrimary ? null : () => makePrimary(native.code),
                        tooltip: native.isPrimary ? 'Главный родной язык' : 'Сделать главным',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, color: AppColors.muted, size: 20),
                        onPressed: _natives.length <= 1 ? null : () => remove(native.code),
                        tooltip: 'Убрать из родных',
                      ),
                    ),
                  if (_natives.length < maxNativeLanguages)
                    ListTile(
                      leading: const Icon(Icons.add, color: AppColors.gold),
                      title: const Text('Добавить язык', style: TextStyle(color: AppColors.gold)),
                      onTap: addNew,
                    ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Поиск по всем ~100 языкам реестра (lib/core/all_languages.dart) — их
  /// слишком много для плоского списка без фильтра, в отличие от трёх
  /// языков в старом picker'е родного языка.
  Future<String?> _pickFromAllLanguages({required Set<String> exclude}) async {
    var query = '';
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.navy2,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final entries = allLanguages.entries
              .where((e) => !exclude.contains(e.key))
              .where((e) =>
                  query.isEmpty || e.value.endonym.toLowerCase().contains(query.toLowerCase()) || e.key == query)
              .toList()
            ..sort((a, b) => a.value.endonym.compareTo(b.value.endonym));
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      autofocus: true,
                      style: const TextStyle(color: AppColors.cream),
                      decoration: const InputDecoration(hintText: 'Поиск языка…'),
                      onChanged: (v) => setSheetState(() => query = v),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final e in entries)
                          ListTile(
                            title: Text(e.value.endonym),
                            onTap: () => Navigator.of(ctx).pop(e.key),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _signOut() async {
    await supabase.auth.signOut();
    if (mounted) context.go('/login');
  }

  void _notReadyYet(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what появится в следующей итерации')),
    );
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

  /// Правим не сам рейтинг, а ту величину, по которой считается лига
  /// (league_rating = rating - 2*RD), плюс отдельно RD. Иначе отладка
  /// врала бы: выставив «рейтинг 2400», разработчик увидел бы у себя не
  /// Алмаз, а лигу на 700 очков ниже — потому что league_rating меньше
  /// рейтинга ровно на два отклонения. RD вынесен отдельным полем, чтобы
  /// можно было проверить и вид новичка (350), и вид наигранного (50).
  Future<void> _editRating() async {
    final current = _rating ?? PlayerRating.newcomer;
    final leagueController =
        TextEditingController(text: '${current.leagueRating}');
    final rdController =
        TextEditingController(text: '${current.deviation.round()}');
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
              'Отладочная настройка. Лига и сложность фраз считаются по '
              'консервативной оценке Glicko-2: рейтинг минус два отклонения. '
              'Первое поле — именно она, пороги лиг ниже даны в ней же. '
              'Сам рейтинг будет выставлен так, чтобы сойтись с этими двумя '
              'числами.',
              style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: leagueController,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Рейтинг в зачёт лиги'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: rdController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'RD: 350 — новичок, 50 — наигранный',
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
              final league = int.tryParse(leagueController.text.trim());
              final rd = int.tryParse(rdController.text.trim());
              Navigator.of(ctx).pop(
                league == null || rd == null ? null : [league, rd],
              );
            },
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    if (entered == null || !mounted) return;
    final leagueValue = entered[0].clamp(0, 99999);
    // Нижняя граница RD — 30: ниже система в реальной игре не опускается
    // (glicko2_update держит её сверху 350, снизу её держит сама формула).
    final rd = entered[1].clamp(30, 350);
    final rating = (leagueValue + 2 * rd).toDouble();

    setState(() => _savingRating = true);
    try {
      // elo, league_rating, league и cefr_level пересчитает триггер
      // trg_sync_rating_mirrors — их отсюда трогать нельзя.
      await supabase
          .from('user_languages')
          .update({
            'rating': rating,
            'rating_deviation': rd.toDouble(),
            'rating_updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('user_id', currentUserId)
          .eq('role', 'learning')
          .eq('is_active', true);
      if (!mounted) return;
      setState(() {
        _rating = PlayerRating(
          rating: rating,
          deviation: rd.toDouble(),
          leagueRating: leagueValue,
        );
        _savingRating = false;
      });
      // Арена держит рейтинг в своём состоянии и сама его не перечитывает.
      notifyProfileChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Рейтинг ${rating.round()} ± $rd · в зачёт лиги '
              '$leagueValue · ${leagueFor(leagueValue).titleWithLevel}'),
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
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('ИНТЕРФЕЙС', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _Row(
                    icon: Icons.language,
                    title: 'Язык интерфейса',
                    trailing: Text('Русский', style: AppFonts.mono(fontSize: 11, color: AppColors.muted)),
                    onTap: () => _notReadyYet('Переключение языка интерфейса'),
                  ),
                  const Divider(height: 1, color: AppColors.line),
                  _Row(
                    icon: Icons.translate,
                    // Множественное число намеренно: полиглот может
                    // назвать родными до шести языков (миграция 0025), а
                    // не только один, как было раньше.
                    title: 'Родные языки',
                    trailing: Text(
                      _natives.isEmpty
                          ? '—'
                          : _natives.length == 1
                              ? allLanguages[_natives.first.code]?.endonym ?? _natives.first.code
                              : '${allLanguages[_natives.firstWhere(
                                    (n) => n.isPrimary,
                                    orElse: () => _natives.first,
                                  ).code]?.endonym} +${_natives.length - 1}',
                      style: AppFonts.mono(fontSize: 11, color: AppColors.muted),
                    ),
                    onTap: _manageNativeLanguages,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text('ТРЕНИРОВКА', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: _Row(
                icon: Icons.style,
                title: 'Карточек за тренировку',
                trailing: _savingDeckSize
                    ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('$_deckSize', style: AppFonts.mono(fontSize: 11, color: AppColors.muted)),
                onTap: _savingDeckSize ? null : _pickDeckSize,
              ),
            ),
            const SizedBox(height: 18),
            Text('ОТЛАДКА', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.danger)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: _Row(
                icon: Icons.emoji_events_outlined,
                title: 'Рейтинг и лига',
                trailing: _savingRating
                    ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(
                        _rating == null
                            ? '—'
                            : '${_rating!.display} ± ${_rating!.deviation.round()}'
                                ' · ${_rating!.league.cefr}',
                        style: AppFonts.mono(fontSize: 11, color: AppColors.muted),
                      ),
                onTap: _savingRating ? null : _editRating,
              ),
            ),
            const SizedBox(height: 18),
            Text('УВЕДОМЛЕНИЯ', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: _Row(
                icon: Icons.notifications_none,
                title: 'Уведомления о матчах',
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
            Text('ПРИВАТНОСТЬ', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _Row(
                    icon: Icons.visibility_off_outlined,
                    title: 'Скрыть меня из рейтинга',
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
                    title: 'Заблокированные игроки',
                    onTap: () => _notReadyYet('Список блокировок'),
                  ),
                  const Divider(height: 1, color: AppColors.line),
                  _Row(
                    icon: Icons.flag_outlined,
                    title: 'Мои жалобы',
                    onTap: () => _notReadyYet('История жалоб'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text('О ПРИЛОЖЕНИИ', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: _Row(
                icon: Icons.info_outline,
                title: 'Версия сборки',
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
                    const SnackBar(content: Text('Версия скопирована')),
                  );
                },
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
                child: const Text('Выйти из аккаунта'),
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
