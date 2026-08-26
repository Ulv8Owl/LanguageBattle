import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'chrolingo_widgets.dart';

/// Живой обратный отсчёт пробного периода — задача итерации: плашка шире
/// прежней, с реальным таймером вместо "осталось N дн.".
///
/// Дедлайн (`trialEndsAt`) — обычная колонка в Supabase (`subscriptions.
/// trial_ends_at`), выставленная сервером при регистрации. Тикает здесь
/// только ОТОБРАЖЕНИЕ: секундная стрелка обновляется локальным таймером
/// раз в секунду, но сам отсчёт идёт от серверной метки времени, поэтому
/// он одинаково верен и после недели без захода в приложение, и посреди
/// сессии — считать это на клиенте не нужно, достаточно читать дедлайн.
class TrialCountdownBanner extends StatefulWidget {
  final DateTime trialEndsAt;

  const TrialCountdownBanner({super.key, required this.trialEndsAt});

  @override
  State<TrialCountdownBanner> createState() => _TrialCountdownBannerState();
}

class _TrialCountdownBannerState extends State<TrialCountdownBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    final clamped = d.isNegative ? Duration.zero : d;
    final h = clamped.inHours.toString().padLeft(2, '0');
    final m = (clamped.inMinutes % 60).toString().padLeft(2, '0');
    final s = (clamped.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.trialEndsAt.difference(DateTime.now().toUtc());
    final expired = left.isNegative;

    return ChPanel(
      borderColor: expired ? AppColors.danger : AppColors.gold,
      boxShadow: expired
          ? null
          : [BoxShadow(color: AppColors.gold.withValues(alpha: 0.16), blurRadius: 18)],
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(
            expired ? Icons.lock_clock : Icons.hourglass_bottom,
            size: 22,
            color: expired ? AppColors.danger : AppColors.gold,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  expired ? 'Пробный период закончился' : 'Пробный период',
                  style: AppFonts.ui(fontSize: 13, weight: FontWeight.w700),
                ),
                if (!expired) ...[
                  const SizedBox(height: 4),
                  Text(
                    _format(left),
                    style: AppFonts.mono(fontSize: 20, weight: FontWeight.w700, color: AppColors.gold),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
