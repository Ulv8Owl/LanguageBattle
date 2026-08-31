import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/all_languages.dart';
import '../../core/nav_state.dart';
import '../../core/supabase_client.dart';
import '../../data/native_languages.dart';

const _supportedLanguages = {
  'en': 'English',
  'es': 'Español',
  'ru': 'Русский',
};

/// Добавление ещё одной языковой пары (до 4 на аккаунт).
///
/// Изучаемый язык всегда выбирается здесь. Родной — только когда у игрока
/// зарегистрирован больше одного (миграция 0025, «Родные языки» в
/// Настройках): полиглот может учить японский именно от китайского, а не
/// от главного родного из профиля, и тогда выбор родного должен быть
/// частью этой формы, а не молчаливым допущением. Если родной один —
/// выбирать нечего, и поле не показывается вовсе.
///
/// Добавление НЕ переключает активную пару и не трогает её рейтинг —
/// новая пара стартует с рейтинга 1500 ± 350 (Glicko-2, миграция 0023) и
/// ждёт, пока её явно выберут активной (тап по плашке на Профиле).
class LanguagePairScreen extends StatefulWidget {
  const LanguagePairScreen({super.key});

  @override
  State<LanguagePairScreen> createState() => _LanguagePairScreenState();
}

class _LanguagePairScreenState extends State<LanguagePairScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<NativeLanguage> _natives = [];
  Set<String> _usedTargets = {};
  String? _selectedTarget;
  String? _selectedNative;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uid = currentUserId;
      final natives = await NativeLanguages.fetch(uid);
      final pairs = await supabase
          .from('user_languages')
          .select('language_code')
          .eq('user_id', uid)
          .eq('role', 'learning');
      final primary = natives.firstWhere(
        (n) => n.isPrimary,
        orElse: () => natives.isEmpty ? const NativeLanguage(code: 'ru', isPrimary: true) : natives.first,
      );
      final used = pairs.map((r) => r['language_code'] as String).toSet();
      final available = _supportedLanguages.keys.where((l) => l != primary.code && !used.contains(l));
      if (!mounted) return;
      setState(() {
        _natives = natives;
        _selectedNative = primary.code;
        _usedTargets = used;
        _selectedTarget = available.isEmpty ? null : available.first;
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

  Future<void> _save() async {
    final target = _selectedTarget;
    final native = _selectedNative;
    if (target == null || native == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await supabase.rpc('add_language_pair', params: {
        'p_target_language': target,
        'p_native_language': native,
      });
      notifyLanguagePairChanged();
      if (!mounted) return;
      if (context.canPop()) context.pop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось добавить пару: $e');
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
                child: _buildBody(),
              ),
      ),
    );
  }

  List<String> get _availableTargets =>
      _supportedLanguages.keys.where((l) => l != _selectedNative && !_usedTargets.contains(l)).toList();

  Widget _buildBody() {
    final available = _availableTargets;

    if (available.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.language, size: 48, color: Colors.white38),
          const SizedBox(height: 16),
          const Text(
            'Все поддерживаемые языки уже добавлены как пары.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Выбор родного языка — только когда их несколько; при одном это
        // было бы полем без выбора, то есть шумом.
        if (_natives.length > 1) ...[
          const Text('С какого родного языка учить', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _selectedNative,
            items: _natives
                .map((n) => DropdownMenuItem(
                      value: n.code,
                      child: Text(allLanguages[n.code]?.endonym ?? n.code),
                    ))
                .toList(),
            onChanged: (v) => setState(() {
              _selectedNative = v;
              // Смена родного меняет допустимые изучаемые (нельзя учить
              // язык от самого себя) — если прежний выбор стал недопустим,
              // явно пересчитываем его здесь же, а не полагаемся на билд:
              // DropdownButtonFormField падает с ассертом, если его
              // текущее значение не входит в список items.
              if (!_availableTargets.contains(_selectedTarget)) {
                _selectedTarget = _availableTargets.isEmpty ? null : _availableTargets.first;
              }
            }),
          ),
          const SizedBox(height: 20),
        ] else
          Text(
            'Родной язык: ${allLanguages[_selectedNative]?.endonym ?? _supportedLanguages[_selectedNative] ?? '—'}',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        const SizedBox(height: 20),
        const Text('Новый изучаемый язык', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _selectedTarget,
          items:
              available.map((l) => DropdownMenuItem(value: l, child: Text(_supportedLanguages[l]!))).toList(),
          onChanged: (v) => setState(() => _selectedTarget = v),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 12),
        const Text(
          'Новая пара стартует с рейтинга 1500 ± 350 и не заменяет текущую активную — '
          'переключиться на неё можно будет тапом по плашке в профиле.',
          style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Добавить'),
        ),
      ],
    );
  }
}
