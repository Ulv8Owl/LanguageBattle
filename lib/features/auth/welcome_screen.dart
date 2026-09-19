import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_locale.dart';
import '../../core/start_destination.dart';
import '../../data/account.dart';

/// Первый экран: «Начать» и «Уже есть аккаунт».
///
/// ═══ ПОЧЕМУ ЗДЕСЬ БОЛЬШЕ НЕ СПРАШИВАЮТ ПОЧТУ ═══
///
/// Раньше приложение встречало формой входа. Это счёт, выставленный до
/// того, как показали товар: человек, скачавший игру про языки, ещё не
/// знает, стоит ли она его почты, — и чаще всего закрывает её прямо
/// здесь.
///
/// «Начать» заводит анонимный аккаунт молча. Языки, уровень, рейтинг и
/// серия с первой же минуты принадлежат ИГРОКУ, а не сессии: короткая
/// регистрация потом достроит этот самый аккаунт, ничего не потеряв.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _loading = false;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Account.startAsGuest();
      await Account.ensureGuestName();
      // Куда дальше, решает общая функция: гость проходит ровно те же
      // шаги, что и вернувшийся игрок, и пропустить их так же не может.
      final destination = await resolveStartDestination();
      await AppLocale.refreshFromServer();
      if (!mounted) return;
      context.go(destination.route);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is AccountError ? e.message : 'Не удалось начать: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset(
                    'assets/branding/chameleon.png',
                    height: 150,
                    // Пиксель-арт: без сглаживания при масштабировании.
                    filterQuality: FilterQuality.none,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'CHROLINGO',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Язык вслух, а не в тетради',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.white60),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 36),
                  ElevatedButton(
                    onPressed: _loading ? null : _start,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Начать'),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: _loading ? null : () => context.push('/login'),
                    child: const Text('Уже есть аккаунт'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
