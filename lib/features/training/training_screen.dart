import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

/// Режим 1 «Одиночная Игра» — вне рейтинга, свой пайплайн через
/// training_sessions/training_rounds (тот же voice_recordings+evaluation_jobs).
/// Не входит в объём Шага 3 (Wizard-of-Oz для Состязания/Дуэли) — здесь
/// только заглушка ради навигации Фазы 0.
class TrainingScreen extends StatelessWidget {
  const TrainingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Одиночная игра')),
      body: const PlaceholderScreen(
        title: 'Одиночная игра',
        note: 'Практика с AI-фидбеком, вне рейтинга — реализуем следом за PvP.',
      ),
    );
  }
}
