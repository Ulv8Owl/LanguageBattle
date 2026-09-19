import 'package:go_router/go_router.dart';

import '../features/arena/arena_shell.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/auth/welcome_screen.dart';
import '../features/auth/splash_gate.dart';
import '../features/battle/battle_results_screen.dart';
import '../features/battle/battle_screen.dart';
import '../features/flashcards/flashcards_screen.dart';
import '../features/matchmaking/matchmaking_screen.dart';
import '../features/onboarding/level_select_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/profile/avatar_editor_screen.dart';
import '../features/profile/settings_screen.dart';
import '../features/training/training_screen.dart';
import '../features/listening/library_screen.dart';
import '../features/listening/player_screen.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const SplashGate()),
    // ПЕРВЫЙ ЭКРАН — НЕ ВХОД. Форма входа на старте это счёт,
    // выставленный до того, как показали товар; «Начать» заводит
    // анонимный аккаунт и пускает играть сразу.
    GoRoute(path: '/welcome', builder: (context, state) => const WelcomeScreen()),
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    // Не «регистрация» в старом смысле: аккаунт уже есть, здесь к нему
    // добавляют ник и пароль. Прогресс при этом не переносится — он и
    // так с самого начала лежит на этом id.
    GoRoute(path: '/register', builder: (context, state) => const RegisterScreen()),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingScreen(),
    ),
    GoRoute(
      path: '/level-select',
      builder: (context, state) => const LevelSelectScreen(),
    ),
    // Проверка уровня — тот же экран «Голоса», но на фразах
    // заявленного уровня и без списания энергии. Возвращает долю
    // правильных ответов вызвавшему экрану (см. TrainingScreen).
    GoRoute(
      path: '/placement/:level',
      builder: (context, state) => TrainingScreen(
        placementLevel: state.pathParameters['level'],
      ),
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
      path: '/listening',
      builder: (context, state) => const LibraryScreen(),
    ),
    GoRoute(
      path: '/listening/:track',
      builder: (context, state) =>
          PlayerScreen(trackId: state.pathParameters['track'] ?? ''),
    ),
    GoRoute(
      path: '/training',
      // ?phrase=N&title=… — последний шаг карточек: тот же «Голос»,
      // но на заранее известной фразе и в один раунд (см. TrainingScreen).
      builder: (context, state) {
        final phrase = int.tryParse(state.uri.queryParameters['phrase'] ?? '');
        final title = state.uri.queryParameters['title'];
        return TrainingScreen(
          fixedPhraseIndex: phrase,
          title: title == null || title.isEmpty ? null : title,
        );
      },
    ),
    GoRoute(
      path: '/flashcards',
      builder: (context, state) => const FlashcardsScreen(),
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
