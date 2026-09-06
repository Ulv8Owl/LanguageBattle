import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_locale.dart';
import '../../core/start_destination.dart';
import '../../core/supabase_client.dart';

/// Куда попасть при холодном старте: не вошёл -> /login; вошёл, но пары
/// языков нет -> /onboarding; пара есть, но уровень ещё не определён ->
/// /level-select; иначе -> /arena.
///
/// Шаг с уровнем нельзя пропустить, закрыв приложение на нём: до
/// placement_done = true игрок будет возвращаться сюда же, потому что
/// иначе он играл бы с рейтингом по умолчанию, так и не выбрав уровень.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _decide());
  }

  Future<void> _decide() async {
    final session = supabase.auth.currentSession;
    if (session == null) {
      if (mounted) context.go('/login');
      return;
    }

    try {
      final destination = await resolveStartDestination();
      // Язык интерфейса читается из профиля здесь, а не только на старте
      // main(): при первом входе на новом устройстве сессии в момент
      // main() ещё нет, и серверное значение прочитать было неоткуда.
      await AppLocale.refreshFromServer();
      if (!mounted) return;
      context.go(destination.route);
    } catch (_) {
      if (mounted) context.go('/onboarding');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
