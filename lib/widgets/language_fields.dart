import 'package:flutter/material.dart';

import '../core/all_languages.dart';
import '../core/theme.dart';

/// Два поля выбора языка — общий виджет для всех мест, где игрок называет,
/// на каком языке говорит и какой учит.
///
/// Мест этих два: проверка уровня при регистрации и Настройки. Одинаковый
/// вид здесь не украшение — это один и тот же выбор, и выглядеть он должен
/// одинаково.
class LanguageChoiceFields extends StatelessWidget {
  final String? speaks;
  final String? learns;
  final VoidCallback onPickSpeaks;
  final VoidCallback onPickLearns;

  const LanguageChoiceFields({
    super.key,
    required this.speaks,
    required this.learns,
    required this.onPickSpeaks,
    required this.onPickLearns,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Field(
          label: 'Говорю на языке',
          code: speaks,
          hint: 'Выбери язык',
          onTap: onPickSpeaks,
        ),
        const SizedBox(height: 12),
        _Field(
          label: 'Изучаю язык',
          code: learns,
          hint: 'Выбери язык',
          onTap: onPickLearns,
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String? code;
  final String hint;
  final VoidCallback onTap;

  const _Field({required this.label, required this.code, required this.hint, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final chosen = code != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.navy3,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: chosen ? AppColors.gold : AppColors.line),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: AppFonts.mono(
                          fontSize: 9, weight: FontWeight.w700, color: AppColors.muted)),
                  const SizedBox(height: 4),
                  Text(
                    chosen ? '${languageFlag(code)}  ${languageName(code!)}' : hint,
                    style: AppFonts.ui(
                      fontSize: 15,
                      weight: FontWeight.w700,
                      color: chosen ? AppColors.cream : AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.expand_more, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}
