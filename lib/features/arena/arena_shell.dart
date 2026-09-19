import 'package:flutter/material.dart';

import '../../core/nav_state.dart';
import '../../core/theme.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _index, children: _tabs),
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
                return Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _index = i),
                    child: Center(
                      child: Icon(
                        _icons[i],
                        size: active ? 26 : 23,
                        color: active ? AppColors.gold : AppColors.muted,
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
