import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/all_languages.dart';
import '../../core/nav_state.dart';
import '../../core/theme.dart';
import '../../data/content_languages.dart';
import '../../data/language_pairs.dart';
import '../../widgets/language_picker.dart';

/// Новая языковая пара: два языка и кнопка «добавить».
///
/// РАНЬШЕ ЗДЕСЬ БЫЛ ФИЛЬТР, а не выбор. Язык, с которого учат, можно было
/// взять только из отдельного реестра «родных языков», а изучаемый — из
/// того, что осталось после вычитания уже заведённых пар. Из-за этого
/// половина сочетаний была недоступна, экран показывал «языков больше нет»
/// на непустом списке, а игрок не понимал, что от него хотят.
///
/// Теперь оба языка выбираются свободно из общего реестра. Запрет ровно
/// один — язык нельзя учить у самого себя, — и о нём говорит сервер, а не
/// спрятанные варианты.
class LanguagePairScreen extends StatefulWidget {
  const LanguagePairScreen({super.key});

  @override
  State<LanguagePairScreen> createState() => _LanguagePairScreenState();
}

class _LanguagePairScreenState extends State<LanguagePairScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;

  /// Языки с готовым банком фраз и слов — только их можно взять в пару.
  /// Реестр знает 32 языка, но учить можно лишь то, что переведено.
  Set<String> _ready = {};

  String? _speaks;
  String? _learns;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ready = await ContentLanguages.ready();
      // Подставляем языки активной пары: чаще всего новую пару заводят от
      // того же языка, с которого уже учат.
      final active = await fetchActivePair();
      if (!mounted) return;
      setState(() {
        _ready = ready;
        _speaks = active?.speaks ?? (ready.isEmpty ? null : ready.first);
        _learns = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить: $e';
      });
    }
  }

  Future<void> _pick({required bool speaks}) async {
    final other = speaks ? _learns : _speaks;
    final picked = await showLanguagePicker(
      context,
      title: speaks ? 'С какого языка переводить' : 'Какой язык изучать',
      ready: _ready,
      // Единственное недоступное — второй язык этой же пары.
      taken: {?other},
      takenNote: 'это второй язык пары',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (speaks) {
        _speaks = picked;
      } else {
        _learns = picked;
      }
      _error = null;
    });
  }

  Future<void> _save() async {
    final speaks = _speaks;
    final learns = _learns;
    if (speaks == null || learns == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await addLanguagePair(speaks: speaks, learns: learns);
      notifyLanguagePairChanged();
      if (!mounted) return;
      if (context.canPop()) context.pop();
    } catch (e) {
      if (mounted) setState(() => _error = languagePairError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Новая языковая пара')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LanguagePairFields(
                      speaks: _speaks,
                      learns: _learns,
                      onPickSpeaks: () => _pick(speaks: true),
                      onPickLearns: () => _pick(speaks: false),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Text(_error!,
                          style: const TextStyle(color: AppColors.danger, fontSize: 13, height: 1.4)),
                    ],
                    const SizedBox(height: 20),
                    const Text(
                      'Новая пара стартует с начального рейтинга и не заменяет текущую активную — '
                      'переключиться на неё можно тапом по плашке в профиле.',
                      style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                    ),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: (_saving || _speaks == null || _learns == null) ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Добавить пару'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Два поля выбора языка — общий виджет для всех мест, где выбирают пару.
///
/// Их два: экран новой пары и проверка уровня при регистрации. Второй
/// появился потому, что игрок, ошибившийся с языками на регистрации, до
/// сих пор не мог это исправить. Одинаковый вид в обоих местах здесь не
/// украшение: это один и тот же выбор, и выглядеть он должен одинаково.
class LanguagePairFields extends StatelessWidget {
  final String? speaks;
  final String? learns;
  final VoidCallback onPickSpeaks;
  final VoidCallback onPickLearns;

  const LanguagePairFields({
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
          label: 'Перевожу с языка',
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
