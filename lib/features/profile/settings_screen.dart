import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/services.dart';

import '../../core/debug_flags.dart';
import '../../core/languages.dart';
import '../../core/supabase_client.dart';
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

  /// Родной язык — на нём показываются фразы раундов и объяснения ошибок.
  String? _nativeLanguage;
  bool _savingLanguage = false;

  /// Сколько карточек выдаётся за одну тренировку.
  int _deckSize = defaultTrainingDeckSize;
  bool _savingDeckSize = false;

  @override
  void initState() {
    super.initState();
    _loadNativeLanguage();
  }

  Future<void> _loadNativeLanguage() async {
    try {
      final row = await supabase
          .from('users')
          .select('native_language, training_deck_size')
          .eq('id', currentUserId)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _nativeLanguage = row?['native_language'] as String?;
        final size = (row?['training_deck_size'] as num?)?.toInt();
        if (size != null && trainingDeckSizes.contains(size)) _deckSize = size;
      });
    } catch (_) {
      // Не удалось — покажем прочерк, менять язык это не мешает.
    }
  }

  Future<void> _pickNativeLanguage() async {
    // Изучаемый язык нужен здесь не для показа, а для запрета: родной и
    // изучаемый совпадать не могут, иначе переводить будет не с чего.
    String? learning;
    try {
      final row = await supabase
          .from('user_languages')
          .select('language_code')
          .eq('user_id', currentUserId)
          .eq('role', 'learning')
          .eq('is_active', true)
          .limit(1)
          .maybeSingle();
      learning = row?['language_code'] as String?;
    } catch (_) {
      learning = null;
    }
    if (!mounted) return;

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
            Text('Родной язык',
                style: AppFonts.ui(fontSize: 15, weight: FontWeight.w800, color: AppColors.cream)),
            const SizedBox(height: 8),
            for (final entry in languageNames.entries)
              ListTile(
                title: Text(entry.value),
                subtitle: entry.key == learning
                    ? const Text('Сейчас это изучаемый язык', style: TextStyle(fontSize: 11))
                    : null,
                trailing: entry.key == _nativeLanguage
                    ? const Icon(Icons.check, color: AppColors.gold)
                    : null,
                enabled: entry.key != learning,
                onTap: () => Navigator.of(ctx).pop(entry.key),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked == null || picked == _nativeLanguage || !mounted) return;

    setState(() => _savingLanguage = true);
    try {
      await supabase.from('users').update({'native_language': picked}).eq('id', currentUserId);
      // Строка родного языка в user_languages идёт в паре с полем в users:
      // по ней считается языковая пара в матчах, и рассинхрон означал бы,
      // что игрок в бою говорит не на том языке, что показан в профиле.
      await supabase
          .from('user_languages')
          .update({'language_code': picked})
          .eq('user_id', currentUserId)
          .eq('role', 'native');
      if (!mounted) return;
      setState(() {
        _nativeLanguage = picked;
        _savingLanguage = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Родной язык: ${languageNames[picked] ?? picked}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingLanguage = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сменить язык: $e')),
      );
    }
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
                    title: 'Родной язык',
                    trailing: _savingLanguage
                        ? const SizedBox(
                            height: 14,
                            width: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            languageNames[_nativeLanguage] ?? '—',
                            style: AppFonts.mono(fontSize: 11, color: AppColors.muted),
                          ),
                    onTap: _savingLanguage ? null : _pickNativeLanguage,
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
