import 'package:go_router/go_router.dart';

import '../features/arena/arena_shell.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/signup_screen.dart';
import '../features/auth/splash_gate.dart';
import '../features/battle/battle_results_screen.dart';
import '../features/battle/battle_screen.dart';
import '../features/matchmaking/matchmaking_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/profile/avatar_editor_screen.dart';
import '../features/profile/settings_screen.dart';
import '../features/training/training_screen.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const SplashGate()),
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    GoRoute(path: '/signup', builder: (context, state) => const SignupScreen()),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingScreen(),
    ),
    GoRoute(
      path: '/arena',
      builder: (context, state) => const ArenaShell(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/avatar',
      builder: (context, state) => const AvatarEditorScreen(),
    ),
    GoRoute(
      path: '/training',
      builder: (context, state) => const TrainingScreen(),
    ),
    GoRoute(
      path: '/matchmaking/:mode',
      builder: (context, state) => MatchmakingScreen(
        gameMode: state.pathParameters['mode']!,
      ),
    ),
    GoRoute(
      path: '/battle/:matchId',
      builder: (context, state) => BattleScreen(
        matchId: state.pathParameters['matchId']!,
      ),
    ),
    GoRoute(
      path: '/battle/:matchId/results',
      builder: (context, state) => BattleResultsScreen(
        matchId: state.pathParameters['matchId']!,
      ),
    ),
  ],
);
