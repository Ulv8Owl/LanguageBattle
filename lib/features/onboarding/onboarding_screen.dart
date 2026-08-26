import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/supabase_client.dart';

const _supportedLanguages = {
  'en': 'English',
  'es': 'Español',
  'ru': 'Русский',
};

/// Онбординг (раздел 2.1): выбор родного/изучаемого языка, никнейм,
/// стартовый рейтинг. Тест уровня (CEFR) — не в этой фазе, elo/CEFR
/// стартуют с дефолтных значений (1000 / A1) и уточняются позже.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  String _nativeLanguage = 'en';
  String _targetLanguage = 'es';
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_nativeLanguage == _targetLanguage) {
      setState(() => _error = 'Родной и изучаемый язык должны отличаться.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final userId = currentUserId;
      await supabase.from('users').update({
        'username': _usernameController.text.trim(),
        'native_language': _nativeLanguage,
      }).eq('id', userId);

      await supabase.from('user_languages').insert([
        {
          'user_id': userId,
          'language_code': _nativeLanguage,
          'role': 'native',
          'cefr_level': 'C2',
          'elo': 1000,
          'league': 'bronze',
        },
        {
          'user_id': userId,
          'language_code': _targetLanguage,
          'role': 'learning',
          'cefr_level': 'A1',
          'elo': 1000,
          'league': 'bronze',
          'is_active': true,
        },
      ]);

      if (!mounted) return;
      context.go('/arena');
    } catch (e) {
      setState(() => _error = 'Не удалось сохранить профиль: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Создание профиля')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _usernameController,
                      decoration: const InputDecoration(labelText: 'Никнейм'),
                      validator: (v) =>
                          (v == null || v.trim().length < 3) ? 'Минимум 3 символа' : null,
                    ),
                    const SizedBox(height: 20),
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
                    const SizedBox(height: 28),
                    ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Начать игру'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
