import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

class FriendsScreen extends StatelessWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: PlaceholderScreen(
        title: 'Друзья',
        note: 'Друзья, рейтинг, поиск по нику — Фаза 5.',
      ),
    );
  }
}
