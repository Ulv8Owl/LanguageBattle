import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import '../../core/nav_state.dart';
import '../../core/theme.dart';
import '../../data/account.dart';
import '../friends/friends_screen.dart';
import '../profile/profile_screen.dart';
import '../streak/streak_screen.dart';
import '../shop/shop_screen.dart';
import 'arena_screen.dart';

/// Нижняя навигация (раздел 5.1, п.2): Профиль / Друзья / Арена / Магазин /
/// Серия — только иконки без подписей, растянуто на всю ширину экрана.
/// Настроек здесь нет: вход в них только через Профиль.
///
/// ПЯТАЯ ВКЛАДКА БЫЛА «НАГРАДАМИ» С КУБКОМ. В ней жили Battle Pass и трек
/// вех — прогресс, которого игрок не чувствовал: очко за выигранный матч
/// в игре, где матчей бывает по одному в день. Серия чувствуется каждый
/// вечер, и огонёк говорит о ней без подписи.
class ArenaShell extends StatefulWidget {
  const ArenaShell({super.key});

  @override
  State<ArenaShell> createState() => _ArenaShellState();
}

class _ArenaShellState extends State<ArenaShell> {
  int _index = ArenaTabs.arena;

  static const _tabs = [
    ProfileScreen(),
    FriendsScreen(),
    ArenaScreen(),
    ShopScreen(),
    StreakScreen(),
  ];

  static const _icons = [
    Icons.person,
    Icons.group,
    Icons.stadium,
    Icons.storefront,
    Icons.local_fire_department,
  ];

  @override
  void initState() {
    super.initState();
    // Пейволл и редактор аватара переключают вкладку извне.
    arenaTabRequest.addListener(_onTabRequested);
  }

  @override
  void dispose() {
    arenaTabRequest.removeListener(_onTabRequested);
    super.dispose();
  }

  void _onTabRequested() {
    if (!mounted) return;
    setState(() => _index = arenaTabRequest.value);
  }

  /// Гостю открыта только Арена.
  ///
  /// ПОЧЕМУ ИМЕННО ОНА. Это то, ради чего игру ставили: сказать вслух и
  /// получить оценку. Всё остальное — друзья, магазин, профиль, серия —
  /// про то, что копится, а копить имеет смысл только на аккаунте, из
  /// которого нельзя выпасть вместе с телефоном.
  bool get _locked => Account.isGuest && _index != ArenaTabs.arena;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: _locked
            ? _GuestWall(
                onRegister: () async {
                  await context.push('/register');
                  // Регистрация могла случиться — перерисовываемся, иначе
                  // стена останется стоять перед уже настоящим игроком.
                  if (mounted) setState(() {});
                },
              )
            : IndexedStack(index: _index, children: _tabs),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppColors.navy2,
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 56,
            child: Row(
              children: List.generate(_tabs.length, (i) {
                final active = i == _index;
                // Замок виден ДО нажатия: вкладка, которая открывается в
                // стену, без него выглядит сломанной.
                final locked = Account.isGuest && i != ArenaTabs.arena;
                return Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _index = i),
                    child: Center(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(
                            _icons[i],
                            size: active ? 26 : 23,
                            color: active ? AppColors.gold : AppColors.muted,
                          ),
                          if (locked)
                            const Positioned(
                              right: -4,
                              bottom: -2,
                              child: Icon(Icons.lock,
                                  size: 11, color: AppColors.muted),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// Что видит гость вместо закрытого раздела.
///
/// НЕ «ДОСТУП ЗАПРЕЩЁН», А ПРЕДЛОЖЕНИЕ. Человек уже играет и уже что-то
/// накопил; здесь ему говорят, что именно он получит, а не то, чего его
/// лишили.
class _GuestWall extends StatelessWidget {
  final Future<void> Function() onRegister;

  const _GuestWall({required this.onRegister});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_outline, size: 40, color: AppColors.muted),
              const SizedBox(height: 14),
              Text(
                'Здесь нужен аккаунт',
                textAlign: TextAlign.center,
                style: AppFonts.ui(fontSize: 17, weight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              const Text(
                'Серия, друзья, магазин и профиль копятся — а копить имеет '
                'смысл только там, откуда не выпадешь вместе с телефоном.\n\n'
                'Регистрация короткая: ник, пароль и, если хотите, почта. '
                'Всё, что вы уже прошли, останется при вас — аккаунт у вас '
                'с первой минуты, ему просто не хватает имени.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.muted, height: 1.5),
              ),
              const SizedBox(height: 22),
              ElevatedButton(
                onPressed: onRegister,
                child: const Text('Пройти регистрацию'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
