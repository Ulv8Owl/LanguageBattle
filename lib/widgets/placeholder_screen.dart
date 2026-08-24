import 'package:flutter/material.dart';

/// Экран-заглушка для Фазы 0/1 — механика ещё не реализована (см. дальнейшие
/// фазы плана из раздела 8 спеки), но пункт меню и переход к нему уже есть.
class PlaceholderScreen extends StatelessWidget {
  final String title;
  final String note;

  const PlaceholderScreen({super.key, required this.title, required this.note});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(
              note,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
