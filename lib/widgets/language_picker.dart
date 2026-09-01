import 'package:flutter/material.dart';

import '../core/all_languages.dart';
import '../core/theme.dart';

/// Выбор языка из общего реестра — один на все три места, где язык
/// выбирают: онбординг, родные языки в Настройках и новая языковая пара.
///
/// Главное, ради чего он общий: языки, для которых ещё нет банка фраз и
/// слов, показываются, но выбрать их нельзя — «скоро». Спрятать их
/// совсем было бы хуже: человек, не увидевший своего языка, решает, что
/// игра его не поддерживает, и уходит навсегда; человек, увидевший
/// «Deutsch — скоро», понимает, что язык в планах. А дать выбрать язык
/// без контента — это тупик на каждом экране: фраза раунда показывается
/// на РОДНОМ языке, и без перевода показывать нечего.
///
/// Возвращает код выбранного языка или null, если игрок закрыл лист.
Future<String?> showLanguagePicker(
  BuildContext context, {
  required String title,

  /// Языки, на которых уже есть контент — только их можно выбрать.
  required Set<String> ready,

  /// Уже занятые коды (другой родной язык, изучаемый язык этой же пары):
  /// показываются с подписью, но недоступны.
  Set<String> taken = const {},
  String takenNote = 'уже выбран',
}) {
  var query = '';
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.navy2,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        final q = query.trim().toLowerCase();
        final entries = allLanguages.entries.where((e) {
          if (q.isEmpty) return true;
          return e.value.endonym.toLowerCase().contains(q) ||
              e.value.accusative.contains(q) ||
              e.key == q;
        }).toList()
          // Доступные — наверх: список из 32 языков, где готовых пока
          // единицы, иначе заставлял бы прокручивать мимо недоступных.
          ..sort((a, b) {
            final aReady = ready.contains(a.key) && !taken.contains(a.key);
            final bReady = ready.contains(b.key) && !taken.contains(b.key);
            if (aReady != bReady) return aReady ? -1 : 1;
            return a.value.endonym.compareTo(b.value.endonym);
          });

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 16),
                Text(title,
                    style: AppFonts.ui(fontSize: 15, weight: FontWeight.w800, color: AppColors.cream)),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    style: const TextStyle(color: AppColors.cream),
                    decoration: const InputDecoration(hintText: 'Поиск языка…'),
                    onChanged: (v) => setSheetState(() => query = v),
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.55),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final e in entries)
                        _LanguageTile(
                          code: e.key,
                          info: e.value,
                          isTaken: taken.contains(e.key),
                          takenNote: takenNote,
                          isReady: ready.contains(e.key),
                          onTap: () => Navigator.of(ctx).pop(e.key),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _LanguageTile extends StatelessWidget {
  final String code;
  final LanguageInfo info;
  final bool isTaken;
  final String takenNote;
  final bool isReady;
  final VoidCallback onTap;

  const _LanguageTile({
    required this.code,
    required this.info,
    required this.isTaken,
    required this.takenNote,
    required this.isReady,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = isReady && !isTaken;
    // Причина недоступности называется прямо: «скоро» и «уже выбран» — это
    // разные вещи, и молча гасить строку в обоих случаях значило бы
    // заставлять игрока гадать, что не так.
    final note = isTaken
        ? takenNote
        : isReady
            ? null
            : 'скоро';
    return ListTile(
      enabled: enabled,
      leading: Text(info.flag, style: const TextStyle(fontSize: 20)),
      title: Text(
        info.endonym,
        style: TextStyle(color: enabled ? AppColors.cream : AppColors.muted),
      ),
      subtitle: note == null
          ? null
          : Text(note, style: const TextStyle(color: AppColors.muted, fontSize: 11)),
      onTap: enabled ? onTap : null,
    );
  }
}
