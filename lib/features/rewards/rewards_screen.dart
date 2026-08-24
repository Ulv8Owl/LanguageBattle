import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

class RewardsScreen extends StatelessWidget {
  const RewardsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: PlaceholderScreen(
        title: 'Награды',
        note: 'Battle Pass, ежедневные задания — Фаза 4.',
      ),
    );
  }
}
