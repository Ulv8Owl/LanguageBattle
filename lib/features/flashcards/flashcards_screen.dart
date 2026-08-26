import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/flashcard_bank.dart';
import '../../widgets/chrolingo_widgets.dart';

/// «Тренировка» (задача итерации) — карточки со словами на языковой паре
/// из профиля. Единственный режим, который НЕ тратит энергию и не требует
/// подписки: он не проходит через LLM/ASR пайплайн вообще, это чистая
/// клиентская механика без AI-оценки, поэтому её незачем закрывать вместе
/// с Одиночной Игрой/Состязанием/Дуэлью.
///
/// Слово показывается на изучаемом языке, переворот карточки открывает
/// перевод на родном. "Знаю"/"Не знаю" — самооценка игрока, не влияет ни
/// на что за пределами сводки в конце сессии (спейсд-репитишн — отдельная
/// будущая задача, не в этом MVP).
class FlashcardsScreen extends StatefulWidget {
  const FlashcardsScreen({super.key});

  @override
  State<FlashcardsScreen> createState() => _FlashcardsScreenState();
}

class _FlashcardsScreenState extends State<FlashcardsScreen> {
  bool _loading = true;
  String? _error;
  String _targetLanguage = 'en';
  String _nativeLanguage = 'ru';

  late List<int> _order;
  int _index = 0;
  bool _flipped = false;
  int _known = 0;
  int _unknown = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _order = List.generate(FlashcardBank.count, (i) => i)..shuffle();
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
      final native = profile?['native_language'] as String?;
      final target = learning?['language_code'] as String?;
      if (native == null || target == null) {
        setState(() {
          _loading = false;
          _error = 'Сначала выбери языковую пару в профиле.';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _nativeLanguage = native;
        _targetLanguage = target;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить карточки: $e';
      });
    }
  }

  void _flip() {
    setState(() => _flipped = !_flipped);
  }

  void _next(bool known) {
    setState(() {
      if (known) {
        _known++;
      } else {
        _unknown++;
      }
      _flipped = false;
      if (_index >= _order.length - 1) {
        _done = true;
      } else {
        _index++;
      }
    });
  }

  void _restart() {
    setState(() {
      _order = List.generate(FlashcardBank.count, (i) => i)..shuffle();
      _index = 0;
      _flipped = false;
      _known = 0;
      _unknown = 0;
      _done = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Тренировка'),
        actions: [
          if (!_loading && _error == null && !_done)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: Text(
                  '${_index + 1} / ${_order.length}',
                  style: AppFonts.mono(fontSize: 11, weight: FontWeight.w700, color: AppColors.gold),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.style, size: 52, color: AppColors.muted),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.cream, fontSize: 13)),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => context.canPop() ? context.pop() : context.go('/arena'),
              child: const Text('Назад на Арену'),
            ),
          ],
        ),
      );
    }
    if (_done) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ChPanel(
              borderColor: AppColors.gold,
              padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
              child: Column(
                children: [
                  Text('Колода пройдена', style: AppFonts.ui(fontSize: 17, weight: FontWeight.w800, color: AppColors.gold)),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ResultStat(value: '$_known', label: 'знаю', color: AppColors.ok),
                      _ResultStat(value: '$_unknown', label: 'повторить', color: AppColors.danger),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(onPressed: _restart, child: const Text('Пройти заново')),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.cream,
                  side: const BorderSide(color: AppColors.lineStrong),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => context.canPop() ? context.pop() : context.go('/arena'),
                child: const Text('Назад на Арену'),
              ),
            ),
          ],
        ),
      );
    }

    final entry = FlashcardBank.words[_order[_index]];
    final front = entry.forLanguage(_targetLanguage);
    final back = entry.forLanguage(_nativeLanguage);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: _FlipCard(
                key: ValueKey(_index),
                front: front,
                back: back,
                flipped: _flipped,
                onTap: _flip,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    side: const BorderSide(color: AppColors.danger),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => _next(false),
                  child: const Text('Не знаю'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.ok),
                  onPressed: () => _next(true),
                  child: const Text('Знаю'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ResultStat extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _ResultStat({required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: AppFonts.ui(fontSize: 24, weight: FontWeight.w800, color: color)),
        Text(label, style: AppFonts.mono(fontSize: 10, color: AppColors.muted)),
      ],
    );
  }
}

/// Карточка с переворотом по оси Y. Обратная сторона контр-повёрнута,
/// чтобы текст на ней не читался зеркально в момент прохождения 90°.
class _FlipCard extends StatefulWidget {
  final String front;
  final String back;
  final bool flipped;
  final VoidCallback onTap;

  const _FlipCard({super.key, required this.front, required this.back, required this.flipped, required this.onTap});

  @override
  State<_FlipCard> createState() => _FlipCardState();
}

class _FlipCardState extends State<_FlipCard> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  @override
  void didUpdateWidget(covariant _FlipCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.flipped != oldWidget.flipped) {
      widget.flipped ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final angle = _controller.value * 3.14159265;
          final showBack = _controller.value >= 0.5;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0015)
              ..rotateY(angle),
            child: showBack
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..rotateY(3.14159265),
                    child: _CardFace(text: widget.back, isFront: false),
                  )
                : _CardFace(text: widget.front, isFront: true),
          );
        },
      ),
    );
  }
}

class _CardFace extends StatelessWidget {
  final String text;
  final bool isFront;

  const _CardFace({required this.text, required this.isFront});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      width: 280,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isFront
              ? const [AppColors.navy3, AppColors.navy1]
              : [AppColors.goldSoft, AppColors.navy1.withValues(alpha: 0.6)],
        ),
        border: Border.all(color: isFront ? AppColors.line : AppColors.gold, width: isFront ? 1 : 1.5),
        borderRadius: BorderRadius.circular(20),
        boxShadow: isFront
            ? null
            : [BoxShadow(color: AppColors.gold.withValues(alpha: 0.18), blurRadius: 24)],
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppFonts.ui(fontSize: 26, weight: FontWeight.w800, color: isFront ? AppColors.cream : AppColors.gold),
      ),
    );
  }
}
