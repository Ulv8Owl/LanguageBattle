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
/// A0 — единственный уровень БЕЗ проверки. Проверять нечего: игрок и так
/// заявил, что языка не знает, и это самый низ шкалы — занизить себя ещё
/// сильнее он не может, а прогонять человека, который не знает ни слова,
/// через раунд с переводом фразы вслух значит встретить его заведомо
/// проваленным заданием.
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

  /// Нужно ли подтверждать выбранный уровень. Не нужно только для самого
  /// нижнего (A0) — см. док-комментарий экрана.
  bool get _needsCheck => _selected != 'a0';

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

  /// Выход из онбординга назад, в меню входа.
  ///
  /// Обязателен именно выход из сессии, а не просто переход на /login:
  /// аккаунт уже создан, и без signOut SplashGate при следующем запуске
  /// снова привёл бы игрока сюда же. Аккаунт при этом никуда не девается —
  /// войдя заново, игрок вернётся к выбору уровня.
  Future<void> _backToLogin() async {
    await supabase.auth.signOut();
    if (mounted) context.go('/login');
  }

  /// Действие главной кнопки: для всех уровней, кроме A0, — прогнать
  /// проверку и разобрать её результат; для A0 — сразу поставить рейтинг.
  Future<void> _start() async {
    final language = _targetLanguage;
    if (language == null) return;

    // A0 проверять нечем и незачем — сразу ставим рейтинг. Процент здесь
    // не показывается: проверки не было, и «100%» было бы неправдой.
    if (!_needsCheck) {
      await _applyLevel(language, null);
      return;
    }

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

  /// [percent] — доля правильных ответов на проверке; null означает, что
  /// проверки не было (уровень A0).
  Future<void> _applyLevel(String language, int? percent) async {
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
      // Без проверки поздравлять не с чем — игрок просто идёт играть.
      if (percent != null) {
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
      }
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
    if (again == true && mounted) await _start();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocale.strings;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.levelSelectTitle),
        // Кнопка выхода стоит СПРАВА, а не слева: слева у Material живёт
        // системная стрелка «назад по стеку», а этот экран открыт через go()
        // и в стеке под ним ничего нет — стрелки там не появится, и место
        // выглядело бы пустым. Здесь же это не «шаг назад», а выход из
        // регистрации в меню входа, и отдельная кнопка это честно
        // показывает.
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: t.levelSelectBack,
            onPressed: _busy ? null : _backToLogin,
          ),
        ],
      ),
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
                  if (!_needsCheck) ...[
                    const SizedBox(height: 4),
                    Text(
                      t.levelSelectNoCheckNote,
                      style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
                    ),
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
                  onPressed: (_busy || _targetLanguage == null) ? null : _start,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_needsCheck
                          ? t.levelSelectAction
                          : t.levelSelectStartWithoutCheck),
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
