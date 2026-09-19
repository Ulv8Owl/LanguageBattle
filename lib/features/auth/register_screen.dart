import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/account.dart';

/// Короткая регистрация: ник, почта, пароль, аватар.
///
/// ═══ ЭТО НЕ СОЗДАНИЕ АККАУНТА, А ЕГО ДОСТРОЙКА ═══
///
/// Аккаунт у игрока уже есть с первой минуты — анонимный. Здесь к нему
/// добавляются ник и пароль; id, языки, рейтинг и серия остаются те же.
/// Поэтому нигде нет слова «зарегистрироваться заново» и нет ни одного
/// шага, на котором прогресс мог бы потеряться.
///
/// ═══ ПОЧЕМУ ШАГИ ИДУТ ИМЕННО ТАК ═══
///
/// Ник — первым и с проверкой на месте: занятый ник должен выясниться
/// ДО того, как игрок придумал пароль, а не после. Почта — следом и её
/// можно пропустить: она нужна только для восстановления доступа, и
/// требовать её, когда человек уже играет, значит терять его на ровном
/// месте. Пароль — обязателен, иначе входить будет нечем. Аватар —
/// последним и тоже необязателен: это украшение, а не доступ.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _controller = PageController();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _repeatController = TextEditingController();

  int _step = 0;
  bool _loading = false;
  String? _error;

  static const _steps = 4;

  @override
  void dispose() {
    _controller.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _repeatController.dispose();
    super.dispose();
  }

  void _go(int step) {
    setState(() {
      _step = step;
      _error = null;
    });
    _controller.animateToPage(
      step,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _claimUsername() async {
    final name = _usernameController.text.trim();
    if (name.length < 3) {
      setState(() => _error = 'Никнейм от 3 до 20 символов');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Account.claimUsername(name);
      if (!mounted) return;
      setState(() => _loading = false);
      _go(1);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is AccountError ? e.message : 'Не получилось: $e';
      });
    }
  }

  void _nextFromEmail({required bool skip}) {
    if (skip) {
      _emailController.clear();
      _go(2);
      return;
    }
    final email = _emailController.text.trim();
    if (!email.contains('@') || email.length < 5) {
      setState(() => _error = 'Похоже, это не почта');
      return;
    }
    _go(2);
  }

  Future<void> _finish() async {
    final password = _passwordController.text;
    if (password.length < 6) {
      setState(() => _error = 'Пароль минимум 6 символов');
      return;
    }
    if (password != _repeatController.text) {
      setState(() => _error = 'Пароли не совпадают');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Account.register(
        password: password,
        email: _emailController.text.trim().isEmpty
            ? null
            : _emailController.text.trim(),
      );
      if (!mounted) return;
      setState(() => _loading = false);
      _go(3);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is AccountError ? e.message : 'Не получилось: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Короткая регистрация'),
        // НАЗАД УЙТИ МОЖНО В ЛЮБОЙ МОМЕНТ. Игрок пришёл сюда из игры, и
        // запирать его в форме — вернейший способ закрыть приложение.
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.canPop() ? context.pop() : context.go('/arena'),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_step + 1) / _steps,
            minHeight: 4,
          ),
        ),
      ),
      body: SafeArea(
        child: PageView(
          controller: _controller,
          // Листается только кнопками: шаги зависят друг от друга, и
          // перелистнутый пальцем ник остался бы незанятым.
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _step1(),
            _step2(),
            _step3(),
            _step4(),
          ],
        ),
      ),
    );
  }

  Widget _frame({
    required String title,
    required String hint,
    required List<Widget> children,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(hint, style: const TextStyle(fontSize: 13, color: Colors.white60)),
            const SizedBox(height: 22),
            ...children,
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _button(String label, VoidCallback? onPressed) => ElevatedButton(
        onPressed: _loading ? null : onPressed,
        child: _loading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label),
      );

  Widget _step1() => _frame(
        title: 'Как вас звать',
        hint: 'Никнейм увидят соперники. Поменять его потом можно в настройках.',
        children: [
          TextField(
            controller: _usernameController,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Никнейм'),
          ),
          const SizedBox(height: 22),
          _button('Далее', _claimUsername),
        ],
      );

  Widget _step2() => _frame(
        title: 'Почта',
        hint: 'Нужна только чтобы вернуть доступ, если забудете пароль. '
            'Подтверждать её не придётся — письма мы не шлём.',
        children: [
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: 22),
          _button('Далее', () => _nextFromEmail(skip: false)),
          const SizedBox(height: 6),
          TextButton(
            onPressed: _loading ? null : () => _nextFromEmail(skip: true),
            child: const Text('Пропустить'),
          ),
        ],
      );

  Widget _step3() => _frame(
        title: 'Пароль',
        hint: 'Без него войти будет нечем: аккаунт останется только на '
            'этом телефоне.',
        children: [
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Пароль'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _repeatController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Ещё раз'),
          ),
          const SizedBox(height: 22),
          _button('Готово', _finish),
        ],
      );

  Widget _step4() => _frame(
        title: 'Аватар',
        hint: 'Последний шаг, и он необязательный: это украшение, а не доступ.',
        children: [
          _button('Выбрать аватар', () => context.go('/avatar')),
          const SizedBox(height: 6),
          TextButton(
            onPressed: _loading ? null : () => context.go('/arena'),
            child: const Text('Выбрать аватар потом'),
          ),
        ],
      );
}
