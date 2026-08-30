import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/services.dart';

import '../../core/debug_flags.dart';
import '../../core/supabase_client.dart';
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

  Future<void> _signOut() async {
    await supabase.auth.signOut();
    if (mounted) context.go('/login');
  }

  void _notReadyYet(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what появится в следующей итерации')),
    );
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
                ],
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
