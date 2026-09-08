import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_locale.dart';
import '../../core/cefr_levels.dart';
import '../../core/all_languages.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/content_languages.dart';
import '../../data/language_pairs.dart';
import '../../widgets/language_picker.dart';
import '../profile/language_pair_screen.dart';
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

  /// Пара, уровень которой подтверждаем.
  ///
  /// ЕЁ МОЖНО ПОМЕНЯТЬ ПРЯМО ЗДЕСЬ. Пара заводится на предыдущем шаге
  /// регистрации, и ошибиться там легко — а исправить было негде: профиля
  /// со списком пар ещё нет, а завести рядом вторую значило бы навсегда
  /// остаться с ненужной первой. Плашка ниже открывает выбор обоих языков.
  LanguagePair? _pair;
  Set<String> _ready = {};

  /// Нужно ли подтверждать выбранный уровень. Не нужно только для самого
  /// нижнего (A0) — см. док-комментарий экрана.
  bool get _needsCheck => _selected != 'a0';

  @override
  void initState() {
    super.initState();
    _loadPair();
  }

  Future<void> _loadPair() async {
    try {
      final ready = await ContentLanguages.ready();
      final pair = await fetchActivePair();
      if (!mounted) return;
      setState(() {
        _ready = ready;
        _pair = pair;
      });
    } catch (_) {
      // Молча: кнопка проверки останется недоступной, и это честнее, чем
      // отправить игрока на проверку неизвестно какого языка.
    }
  }

  /// Смена языков пары прямо на этом экране.
  ///
  /// Меняется существующая пара, а не заводится новая: у игрока она пока
  /// одна, и вторая, ненужная, осталась бы с ним навсегда. Рейтинг и
  /// подтверждённый уровень при смене изучаемого языка сбрасываются — они
  /// относились к прежнему языку (см. retarget_language_pair).
  Future<void> _editPair() async {
    final pair = _pair;
    if (pair == null || _busy) return;
    var speaks = pair.speaks;
    var learns = pair.learns;

    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.navy2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                20, 18, 20, 18 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Языковая пара',
                    style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800)),
                const SizedBox(height: 14),
                LanguagePairFields(
                  speaks: speaks,
                  learns: learns,
                  onPickSpeaks: () async {
                    final picked = await showLanguagePicker(ctx,
                        title: 'С какого языка переводить',
                        ready: _ready,
                        taken: {learns},
                        takenNote: 'это второй язык пары');
                    if (picked != null) setSheet(() => speaks = picked);
                  },
                  onPickLearns: () async {
                    final picked = await showLanguagePicker(ctx,
                        title: 'Какой язык изучать',
                        ready: _ready,
                        taken: {speaks},
                        takenNote: 'это второй язык пары');
                    if (picked != null) setSheet(() => learns = picked);
                  },
                ),
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: speaks == learns ? null : () => Navigator.pop(ctx, true),
                  child: const Text('Сохранить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (changed != true || !mounted) return;
    if (speaks == pair.speaks && learns == pair.learns) return;
    setState(() => _busy = true);
    try {
      await retargetLanguagePair(pair: pair, speaks: speaks, learns: learns);
      await _loadPair();
    } catch (e) {
      if (mounted) setState(() => _error = languagePairError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
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
    final language = _pair?.learns;
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
                  const SizedBox(height: 14),
                  _PairBanner(pair: _pair, onTap: _busy ? null : _editPair),
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
                  onPressed: (_busy || _pair == null) ? null : _start,
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

/// Плашка пары над выбором уровня: с какого языка и какой изучаем.
///
/// Не украшение. Уровень подтверждается ДЛЯ КОНКРЕТНОЙ пары, и игрок,
/// ошибшийся с языками шагом раньше, до сих пор проходил проверку не того
/// языка, даже не понимая этого: на экране не было написано, о каком языке
/// вообще речь.
class _PairBanner extends StatelessWidget {
  final LanguagePair? pair;
  final VoidCallback? onTap;

  const _PairBanner({required this.pair, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = pair;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.navy3,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ЯЗЫКОВАЯ ПАРА',
                      style: AppFonts.mono(
                          fontSize: 9, weight: FontWeight.w700, color: AppColors.muted)),
                  const SizedBox(height: 5),
                  Text(
                    p == null
                        ? 'Загружаем…'
                        : '${languageFlag(p.speaks)} ${languageName(p.speaks)}'
                            '  →  ${languageFlag(p.learns)} ${languageName(p.learns)}',
                    style: AppFonts.ui(fontSize: 15, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const Icon(Icons.edit_outlined, size: 18, color: AppColors.gold),
          ],
        ),
      ),
    );
  }
}
