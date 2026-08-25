import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../widgets/lexarena_widgets.dart';

/// Battle Pass и ежедневные задания (раздел 2.6) визуально готовы под
/// макет, но БЕЗ реального бэкенда: таблицы battle_pass_seasons/progress
/// существуют, но заводить сезоны, вести очки и генерировать ежедневные
/// квесты — отдельная задача Фазы 4, которую этот проход не покрывает.
/// Честно показываем это как заготовку, а не выдуманные цифры.
class RewardsScreen extends StatelessWidget {
  const RewardsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Награды', style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800)),
          const SizedBox(height: 14),
          LxPanel(
            borderColor: AppColors.gold,
            boxShadow: [BoxShadow(color: AppColors.gold.withValues(alpha: 0.16), blurRadius: 22)],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('BATTLE PASS · СЕЗОН 1', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
                const SizedBox(height: 8),
                const Text('Ещё не запущен', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.cream)),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: const LinearProgressIndicator(
                    value: 0,
                    minHeight: 6,
                    backgroundColor: AppColors.navy1,
                    valueColor: AlwaysStoppedAnimation(AppColors.gold),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Сезоны, очки и вехи наград появятся в следующей итерации — сейчас это только визуальная заготовка экрана.',
                  style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text('ЕЖЕДНЕВНЫЕ ЗАДАНИЯ', style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
          const SizedBox(height: 10),
          const LxPanel(
            child: Text(
              'Квесты появятся вместе с Battle Pass (Фаза 4).',
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
