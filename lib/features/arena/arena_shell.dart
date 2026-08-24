import 'package:flutter/material.dart';

import '../friends/friends_screen.dart';
import '../profile/profile_screen.dart';
import '../rewards/rewards_screen.dart';
import '../shop/shop_screen.dart';
import 'arena_screen.dart';

/// Нижняя навигация (раздел 5.1, п.2): Профиль / Друзья / Арена / Магазин /
/// Награды, только иконки без подписей.
class ArenaShell extends StatefulWidget {
  const ArenaShell({super.key});

  @override
  State<ArenaShell> createState() => _ArenaShellState();
}

class _ArenaShellState extends State<ArenaShell> {
  int _index = 2;

  static const _tabs = [
    ProfileScreen(),
    FriendsScreen(),
    ArenaScreen(),
    ShopScreen(),
    RewardsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(index: _index, children: _tabs),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Профиль'),
          BottomNavigationBarItem(icon: Icon(Icons.group), label: 'Друзья'),
          BottomNavigationBarItem(icon: Icon(Icons.stadium), label: 'Арена'),
          BottomNavigationBarItem(icon: Icon(Icons.storefront), label: 'Магазин'),
          BottomNavigationBarItem(icon: Icon(Icons.emoji_events), label: 'Награды'),
        ],
      ),
    );
  }
}
