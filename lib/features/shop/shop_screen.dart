import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

class ShopScreen extends StatelessWidget {
  const ShopScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: PlaceholderScreen(
        title: 'Магазин',
        note: 'Рамки, эмоции, внешность, Battle Pass — Фаза 4.',
      ),
    );
  }
}
