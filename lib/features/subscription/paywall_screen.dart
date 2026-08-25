import 'package:flutter/material.dart';

import '../../core/nav_state.dart';
import '../../core/theme.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Экран "нужна подписка, чтобы продолжить играть" (задача 5 итерации).
/// Показывается вместо обычного потока при тапе на ЛЮБОЙ из трёх режимов,
/// когда пробный период кончился и платная подписка не оформлена —
/// включая Одиночную Игру.
class PaywallScreen extends StatelessWidget {
  /// Название режима, в который игрок пытался войти.
  final String modeName;

  const PaywallScreen({super.key, required this.modeName});

  /// Показывает пейволл поверх текущего экрана.
  static Future<void> show(BuildContext context, String modeName) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PaywallScreen(modeName: modeName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(Icons.lock_outline, size: 56, color: AppColors.gold),
              const SizedBox(height: 18),
              Text(
                'Нужна подписка,\nчтобы продолжить играть',
                textAlign: TextAlign.center,
                style: AppFonts.ui(fontSize: 22, weight: FontWeight.w800, color: AppColors.gold),
              ),
              const SizedBox(height: 12),
              Text(
                'Пробный период закончился. «$modeName» и остальные режимы '
                'открываются вместе с подпиской.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 22),
              ChPanel(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    _Perk('Все три режима: Одиночная Игра, Состязание, Дуэль'),
                    SizedBox(height: 8),
                    _Perk('Эксклюзивная косметика с меткой «★ Подписка»'),
                    SizedBox(height: 8),
                    _Perk('Подписочная ветка наград Battle Pass'),
                  ],
                ),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  openShopSubscription();
                },
                child: const Text('Перейти к подписке'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Perk extends StatelessWidget {
  final String text;

  const _Perk(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check, size: 16, color: AppColors.ok),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12, color: AppColors.cream, height: 1.4)),
        ),
      ],
    );
  }
}
