import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: PlaceholderScreen(
        title: 'Профиль',
        note: 'Статистика, лига, экипированные предметы — Фаза 4-5.',
      ),
    );
  }
}
