import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/all_languages.dart';
import '../../core/supabase_client.dart';
import '../../data/content_languages.dart';
import '../../data/signup_rows.dart';
import '../../widgets/language_picker.dart';

/// Онбординг (раздел 2.1): выбор родного/изучаемого языка, никнейм,
/// стартовый рейтинг. Тест уровня (CEFR) — не в этой фазе, рейтинг/CEFR
/// стартуют со значений новичка Glicko-2 (1500 ± 350, лига A1) и
/// уточняются игрой.
///
/// Языки выбираются из общего реестра (all_languages.dart) тем же
/// пикером, что и везде: доступны те, для которых уже есть банк фраз и
/// слов, остальные показаны с пометкой «скоро». Выпадающие списки
/// заменены на пикер именно поэтому — тридцать с лишним языков в
/// DropdownButton выглядели бы как простыня без поиска и без объяснения,
/// почему половина недоступна.
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

  /// Языки с готовым контентом. Пустое множество до первой загрузки —
  /// пикер в этот момент ещё не открыть, кнопки ведут в него же.
  Set<String> _ready = {};

  @override
  void initState() {
    super.initState();
    _loadReady();
  }

  Future<void> _loadReady() async {
    final ready = await ContentLanguages.ready();
    if (!mounted) return;
    setState(() {
      _ready = ready;
      // Значения по умолчанию обязаны быть из готовых языков: иначе игрок,
      // не открывший пикер вовсе, зарегистрируется с парой, в которой
      // нечего показывать.
      if (!ready.contains(_nativeLanguage)) _nativeLanguage = ready.first;
      if (!ready.contains(_targetLanguage) || _targetLanguage == _nativeLanguage) {
        _targetLanguage = ready.firstWhere((l) => l != _nativeLanguage, orElse: () => _nativeLanguage);
      }
    });
  }

  Future<void> _pick({required bool isNative}) async {
    final picked = await showLanguagePicker(
      context,
      title: isNative ? 'Родной язык' : 'Изучаемый язык',
      ready: _ready,
      taken: {isNative ? _targetLanguage : _nativeLanguage},
      takenNote: isNative ? 'это изучаемый язык' : 'это твой родной язык',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isNative) {
        _nativeLanguage = picked;
      } else {
        _targetLanguage = picked;
      }
    });
  }

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

      await supabase.from('user_languages').insert(signupLanguageRows(
        userId: userId,
        nativeLanguage: _nativeLanguage,
        targetLanguage: _targetLanguage,
      ));

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
                    _LanguageField(
                      code: _nativeLanguage,
                      onTap: _ready.isEmpty ? null : () => _pick(isNative: true),
                    ),
                    const SizedBox(height: 20),
                    const Text('Изучаемый язык', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    _LanguageField(
                      code: _targetLanguage,
                      onTap: _ready.isEmpty ? null : () => _pick(isNative: false),
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

/// Поле выбора языка: флаг, название и стрелка — открывает общий пикер.
/// Пока список готовых языков ещё грузится, поле неактивно: дать нажать и
/// показать пустой список хуже, чем подождать долю секунды.
class _LanguageField extends StatelessWidget {
  final String code;
  final VoidCallback? onTap;

  const _LanguageField({required this.code, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: const InputDecoration(),
        child: Row(
          children: [
            Text(languageFlag(code), style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(child: Text(languageName(code))),
            const Icon(Icons.expand_more, size: 20),
          ],
        ),
      ),
    );
  }
}
