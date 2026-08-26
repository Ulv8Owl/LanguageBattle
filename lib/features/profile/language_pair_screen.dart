import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/nav_state.dart';
import '../../core/supabase_client.dart';

const _supportedLanguages = {
  'en': 'English',
  'es': 'Español',
  'ru': 'Русский',
};

/// Добавление ещё одной языковой пары (до 4 на аккаунт) — задача итерации.
///
/// Родной язык фиксирован (меняется не здесь — это отдельная задача, не
/// запрошенная в этом заходе), выбирается только НОВЫЙ изучаемый язык.
/// Добавление НЕ переключает активную пару и не трогает её рейтинг —
/// новая пара стартует с ELO 1000 и ждёт, пока её явно выберут активной
/// (тап по плашке на Профиле).
class LanguagePairScreen extends StatefulWidget {
  const LanguagePairScreen({super.key});

  @override
  State<LanguagePairScreen> createState() => _LanguagePairScreenState();
}

class _LanguagePairScreenState extends State<LanguagePairScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _nativeLanguage;
  Set<String> _usedTargets = {};
  String? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uid = currentUserId;
      final profile = await supabase.from('users').select('native_language').eq('id', uid).maybeSingle();
      final pairs = await supabase
          .from('user_languages')
          .select('language_code')
          .eq('user_id', uid)
          .eq('role', 'learning');
      final native = profile?['native_language'] as String?;
      final used = pairs.map((r) => r['language_code'] as String).toSet();
      final available = _supportedLanguages.keys.where((l) => l != native && !used.contains(l));
      if (!mounted) return;
      setState(() {
        _nativeLanguage = native;
        _usedTargets = used;
        _selected = available.isEmpty ? null : available.first;
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
    final target = _selected;
    if (target == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await supabase.rpc('add_language_pair', params: {'p_target_language': target});
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

  Widget _buildBody() {
    final available = _supportedLanguages.keys.where((l) => l != _nativeLanguage && !_usedTargets.contains(l)).toList();

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
        Text('Родной язык: ${_supportedLanguages[_nativeLanguage] ?? '—'}',
            style: const TextStyle(color: Colors.white54, fontSize: 13)),
        const SizedBox(height: 20),
        const Text('Новый изучаемый язык', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _selected,
          items: available.map((l) => DropdownMenuItem(value: l, child: Text(_supportedLanguages[l]!))).toList(),
          onChanged: (v) => setState(() => _selected = v),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 12),
        const Text(
          'Новая пара стартует с рейтинга 1000 и не заменяет текущую активную — '
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
