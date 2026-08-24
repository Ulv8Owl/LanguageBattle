import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/supabase_client.dart';

/// Decides where to land on cold start: logged out -> /login; logged in but
/// no language pair set yet -> /onboarding; otherwise -> /arena.
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
      final languages = await supabase
          .from('user_languages')
          .select('id')
          .eq('user_id', session.user.id)
          .limit(1);
      if (!mounted) return;
      if (languages.isEmpty) {
        context.go('/onboarding');
      } else {
        context.go('/arena');
      }
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
