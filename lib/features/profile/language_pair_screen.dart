import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/nav_state.dart';
import '../../core/supabase_client.dart';

const _supportedLanguages = {
  'en': 'English',
  'es': 'Español',
  'ru': 'Русский',
};

/// Смена языковой пары из Профиля (задача итерации). Одна активная пара на
/// аккаунт — как и в остальном приложении (Арена, бой, матчмейкинг всегда
/// берут ровно одну строку `role='learning'`), поэтому смена пары не
/// добавляет вторую пару поверх старой, а полностью пересоздаёт обе строки
/// `user_languages`: старый прогресс (ELO/лига) в прежней паре при этом
/// сбрасывается — так же, как если бы игрок проходил онбординг заново.
class LanguagePairScreen extends StatefulWidget {
  const LanguagePairScreen({super.key});

  @override
  State<LanguagePairScreen> createState() => _LanguagePairScreenState();
}

class _LanguagePairScreenState extends State<LanguagePairScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  late String _nativeLanguage;
  late String _targetLanguage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uid = currentUserId;
      final profile = await supabase.from('users').select('native_language').eq('id', uid).maybeSingle();
      final learning = await supabase
          .from('user_languages')
          .select('language_code')
          .eq('user_id', uid)
          .eq('role', 'learning')
          .limit(1)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _nativeLanguage = (profile?['native_language'] as String?) ?? 'en';
        _targetLanguage = (learning?['language_code'] as String?) ?? 'es';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить текущую пару: $e';
      });
    }
  }

  Future<void> _save() async {
    if (_nativeLanguage == _targetLanguage) {
      setState(() => _error = 'Родной и изучаемый язык должны отличаться.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final uid = currentUserId;
      await supabase.from('users').update({'native_language': _nativeLanguage}).eq('id', uid);

      // Одна активная пара на аккаунт: старые строки под прежнюю пару
      // удаляются, новые заводятся заново — см. комментарий у класса.
      await supabase.from('user_languages').delete().eq('user_id', uid);
      await supabase.from('user_languages').insert([
        {
          'user_id': uid,
          'language_code': _nativeLanguage,
          'role': 'native',
          'cefr_level': 'C2',
          'elo': 1000,
          'league': 'bronze',
        },
        {
          'user_id': uid,
          'language_code': _targetLanguage,
          'role': 'learning',
          'cefr_level': 'A1',
          'elo': 1000,
          'league': 'bronze',
        },
      ]);

      notifyLanguagePairChanged();
      if (!mounted) return;
      if (context.canPop()) context.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Не удалось сохранить: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Языковая пара')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Родной язык', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _nativeLanguage,
                      items: _supportedLanguages.entries
                          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                          .toList(),
                      onChanged: (v) => setState(() => _nativeLanguage = v!),
                    ),
                    const SizedBox(height: 20),
                    const Text('Изучаемый язык', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _targetLanguage,
                      items: _supportedLanguages.entries
                          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                          .toList(),
                      onChanged: (v) => setState(() => _targetLanguage = v!),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      'Смена пары сбрасывает рейтинг (ELO) и лигу для нового языка — '
                      'это как заново пройти онбординг.',
                      style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Сохранить'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
