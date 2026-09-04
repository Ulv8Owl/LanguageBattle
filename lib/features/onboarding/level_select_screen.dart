import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_locale.dart';
import '../../core/cefr_levels.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Третий шаг регистрации: игрок называет свой уровень владения языком, а
/// игра его проверяет.
///
/// Зачем проверка, а не просто выбор. Стартовый рейтинг задаёт всё
/// остальное — сложность фраз, лигу, соперников в подборе. Без проверки
/// любой мог бы объявить себя C2 и попасть в Алмаз, где ему нечего делать,
/// а соперникам нечего с ним делать. Поэтому заявка подтверждается одной
/// Одиночной Игрой на фразах заявленного уровня (>= 60% правильного), и
/// только после неё вызывается set_placement_rating.
///
/// ЛИГ И КУБКОВ ЗДЕСЬ НЕТ намеренно. «Олово», «Бронза» и тем более рейтинг
/// в очках — игровые понятия, которые новичку в этот момент ещё ничего не
/// говорят и только мешают ответить на простой вопрос «насколько хорошо ты
/// знаешь язык». Связь «уровень → рейтинг → лига» игрок увидит на Арене,
/// уже после проверки.
class LevelSelectScreen extends StatefulWidget {
  const LevelSelectScreen({super.key});

  @override
  State<LevelSelectScreen> createState() => _LevelSelectScreenState();
}

class _LevelSelectScreenState extends State<LevelSelectScreen> {
  /// По умолчанию — A1, а не A0 и не середина шкалы: человек, который
  /// открыл приложение для изучения языка, чаще всего что-то уже знает, но
  /// завышать за него не надо — проверку он всё равно будет проходить.
  String _selected = 'a1';
  bool _busy = false;
  String? _error;

  /// Изучаемый язык активной пары — его и просим подтвердить.
  String? _targetLanguage;

  @override
  void initState() {
    super.initState();
    _loadTargetLanguage();
  }

  Future<void> _loadTargetLanguage() async {
    try {
      final row = await supabase
          .from('user_languages')
          .select('language_code')
          .eq('user_id', currentUserId)
          .eq('role', 'learning')
          .eq('is_active', true)
          .limit(1)
          .maybeSingle();
      if (!mounted) return;
      setState(() => _targetLanguage = row?['language_code'] as String?);
    } catch (_) {
      // Молча: кнопка проверки останется недоступной, и это честнее, чем
      // отправить игрока на проверку неизвестно какого языка.
    }
  }

  /// Запустить проверку и разобрать её результат.
  Future<void> _runCheck() async {
    final language = _targetLanguage;
    if (language == null) return;

    // Экран проверки возвращает долю правильных ответов (0..1) — см.
    // TrainingScreen._finishSession. null означает «игрок ушёл с проверки
    // кнопкой назад»: это не провал, просто ничего не произошло.
    final ratio = await context.push<double>('/placement/$_selected');
    if (ratio == null || !mounted) return;

    final percent = (ratio * 100).round();
    if (ratio >= placementPassRatio) {
      await _applyLevel(language, percent);
    } else {
      await _showFailed(percent);
    }
  }

  Future<void> _applyLevel(String language, int percent) async {
    final t = AppLocale.strings;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await supabase.rpc('set_placement_rating', params: {
        'p_target_language': language,
        'p_level': _selected,
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.navy2,
          title: Text(t.levelCheckPassedTitle),
          content: Text(
            t.levelCheckPassedBody(percent),
            style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t.levelCheckToArena),
            ),
          ],
        ),
      );
      if (!mounted) return;
      context.go('/arena');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.levelSelectFailed(e);
      });
    }
  }

  /// Проверка не сдана. Ровно две осмысленные кнопки: пройти ещё раз тот же
  /// уровень или выбрать другой — третьего («всё равно пропустить») нет,
  /// иначе проверка не значила бы ничего.
  Future<void> _showFailed(int percent) async {
    final t = AppLocale.strings;
    final again = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.navy2,
        title: Text(t.levelCheckFailedTitle),
        content: Text(
          t.levelCheckFailedBody(percent),
          style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.levelCheckPickAnother),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.levelCheckRetry),
          ),
        ],
      ),
    );
    if (again == true && mounted) await _runCheck();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocale.strings;
    return Scaffold(
      appBar: AppBar(title: Text(t.levelSelectTitle)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    t.levelSelectIntro,
                    style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
                  ),
                  const SizedBox(height: 18),
                  for (final level in cefrLevels) ...[
                    _LevelTile(
                      code: level.label,
                      name: t.levelName(level.code),
                      selected: _selected == level.code,
                      onTap: _busy ? null : () => setState(() => _selected = level.code),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  // Пока не знаем изучаемый язык — идти на проверку некуда.
                  onPressed: (_busy || _targetLanguage == null) ? null : _runCheck,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(t.levelSelectAction),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка уровня: код слева (A2), название справа («Продолжающий»).
/// Ни лиги, ни кубка, ни числа рейтинга — см. док-комментарий экрана.
class _LevelTile extends StatelessWidget {
  final String code;
  final String name;
  final bool selected;
  final VoidCallback? onTap;

  const _LevelTile({
    required this.code,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChPanel(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  code,
                  style: AppFonts.mono(
                    fontSize: 13,
                    weight: FontWeight.w800,
                    color: selected ? AppColors.gold : AppColors.muted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  style: AppFonts.ui(
                    fontSize: 14,
                    weight: selected ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? AppColors.gold : AppColors.lineStrong,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
