import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/nav_state.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../core/word_packs.dart';
import '../../data/flashcard_bank.dart';
import '../../widgets/chrolingo_widgets.dart';

/// «Тренировка» — карточки со словами на языковой паре из профиля.
/// Единственный режим, который НЕ тратит энергию и не требует подписки: он
/// не проходит через LLM/ASR пайплайн вообще, это чистая клиентская
/// механика без AI-оценки, поэтому её незачем закрывать вместе с
/// Одиночной Игрой/Состязанием/Дуэлью.
///
/// Слово показывается на изучаемом языке, переворот карточки открывает
/// перевод на родном. "Знаю" начисляет монеты за КАЖДОЕ НОВОЕ слово (раз в
/// жизни на слово, см. mark_word_learned) — "Не знаю" не наказывает и не
/// платит, это самооценка без давления.
///
/// Банк слов разбит на 6 уровней (по числу лиг) × 10 паков по 100 слов.
/// Уровень выбирается на плашке режима в Арене (по умолчанию — по лиге
/// игрока), пак — прямо здесь через кнопку в правом верхнем углу.
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

  int _levelIndex = 0;
  int _packIndex = 0;
  List<WordPackInfo> _catalog = [];
  List<FlashcardEntry> _levelWords = [];
  List<FlashcardEntry> _packWords = [];

  late List<int> _order;
  int _index = 0;
  bool _flipped = false;
  int _known = 0;
  int _unknown = 0;
  int _coinsEarned = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<WordPackInfo> get _levelPacks =>
      _catalog.where((p) => p.levelIndex == _levelIndex).toList()
        ..sort((a, b) => a.packIndex.compareTo(b.packIndex));

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final uid = currentUserId;
      final profile = await supabase.from('users').select('native_language').eq('id', uid).maybeSingle();
      final learning = await supabase
          .from('user_languages')
          .select('language_code, elo')
          .eq('user_id', uid)
          .eq('role', 'learning')
          .eq('is_active', true)
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

      final elo = (learning?['elo'] as num?)?.toInt() ?? 1000;
      final requested = trainingLevelRequest.value;
      trainingLevelRequest.value = -1; // разово — дальше снова по лиге
      final defaultLevel = leagueIndexForElo(elo);
      var level = (requested >= 0 && requested <= 5) ? requested : defaultLevel;

      final catalog = await WordPackCatalog.fetch();

      // Пак по умолчанию: первый купленный пак выбранного уровня; если в
      // этом уровне ещё ничего не куплено (игрок только что поднялся в
      // лигу, но набор не купил) — откатываемся на гарантированно
      // бесплатный 0/0, а не показываем пустой/недоступный уровень.
      var pack = 0;
      final ownedInLevel = catalog.where((p) => p.levelIndex == level && p.owned).toList()
        ..sort((a, b) => a.packIndex.compareTo(b.packIndex));
      if (ownedInLevel.isNotEmpty) {
        pack = ownedInLevel.first.packIndex;
      } else if (level != 0) {
        level = 0;
        pack = 0;
      }

      final levelWords = await FlashcardBank.loadLevel(level);
      final packWords = FlashcardBank.packSlice(levelWords, pack);

      if (!mounted) return;
      setState(() {
        _nativeLanguage = native;
        _targetLanguage = target;
        _levelIndex = level;
        _packIndex = pack;
        _catalog = catalog;
        _levelWords = levelWords;
        _packWords = packWords;
        _order = List.generate(packWords.length, (i) => i)..shuffle();
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

  void _switchPack(WordPackInfo target) {
    if (!target.owned) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Сначала купи этот набор в Магазине'),
        action: SnackBarAction(
          label: 'Магазин',
          onPressed: () {
            openShopWordPacks();
            context.go('/arena');
          },
        ),
      ));
      return;
    }
    setState(() {
      _packIndex = target.packIndex;
      _packWords = FlashcardBank.packSlice(_levelWords, target.packIndex);
      _order = List.generate(_packWords.length, (i) => i)..shuffle();
      _index = 0;
      _flipped = false;
      _known = 0;
      _unknown = 0;
      _coinsEarned = 0;
      _done = false;
    });
  }

  void _openPackMenu() {
    final packs = _levelPacks;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        constraints: const BoxConstraints(maxHeight: 420),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.navy2, AppColors.navy1],
          ),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.lineStrong, borderRadius: BorderRadius.circular(2)),
            ),
            Text('Наборы слов', style: AppFonts.ui(fontSize: 15, weight: FontWeight.w800)),
            const SizedBox(height: 10),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: packs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final p = packs[i];
                  final selected = p.packIndex == _packIndex;
                  return _PackTile(
                    pack: p,
                    selected: selected,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _switchPack(p);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _flip() {
    setState(() => _flipped = !_flipped);
  }

  void _next(bool known) {
    if (known) {
      final globalWordIndex = _packIndex * wordsPerPack + _order[_index];
      WordPackCatalog.markLearned(_levelIndex, globalWordIndex).then((coins) {
        if (!mounted || coins <= 0) return;
        setState(() => _coinsEarned += coins);
      });
    }
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
      _order = List.generate(_packWords.length, (i) => i)..shuffle();
      _index = 0;
      _flipped = false;
      _known = 0;
      _unknown = 0;
      _coinsEarned = 0;
      _done = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Тренировка'),
        actions: [
          if (!_loading && _error == null) ...[
            if (!_done)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Center(
                  child: Text(
                    '${_index + 1} / ${_order.length}',
                    style: AppFonts.mono(fontSize: 11, weight: FontWeight.w700, color: AppColors.gold),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: GestureDetector(
                  onTap: _openPackMenu,
                  child: ChPill(
                    icon: const Icon(Icons.style, size: 12, color: AppColors.cyan),
                    label: (_levelPacks.firstWhere(
                      (p) => p.packIndex == _packIndex,
                      orElse: () => WordPackInfo(
                        levelIndex: _levelIndex,
                        packIndex: _packIndex,
                        price: 0,
                        owned: true,
                        leagueLocked: false,
                      ),
                    )).rangeLabel,
                  ),
                ),
              ),
            ),
          ],
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
                      _ResultStat(value: '+$_coinsEarned', label: 'монет', color: AppColors.gold),
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

    final entry = _packWords[_order[_index]];
    final front = entry.forLanguage(_targetLanguage);
    final back = entry.forLanguage(_nativeLanguage);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: _FlipCard(
                key: ValueKey('$_levelIndex-$_packIndex-$_index'),
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

class _PackTile extends StatelessWidget {
  final WordPackInfo pack;
  final bool selected;
  final VoidCallback onTap;

  const _PackTile({required this.pack, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final locked = !pack.owned;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.gold.withValues(alpha: 0.12) : Colors.transparent,
          border: Border.all(color: selected ? AppColors.gold : AppColors.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              locked ? Icons.lock_outline : Icons.style,
              size: 16,
              color: locked ? AppColors.muted : (selected ? AppColors.gold : AppColors.cream),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                pack.rangeLabel,
                style: AppFonts.ui(
                  fontSize: 13,
                  weight: FontWeight.w700,
                  color: locked ? AppColors.muted : AppColors.cream,
                ),
              ),
            ),
            if (locked)
              pack.leagueLocked
                  ? Text('лига выше', style: AppFonts.mono(fontSize: 9, color: AppColors.muted))
                  : ChPill(
                      icon: const Icon(Icons.circle, size: 9, color: AppColors.gold),
                      label: '${pack.price}',
                    )
            else if (selected)
              const Icon(Icons.check_circle, size: 16, color: AppColors.gold),
          ],
        ),
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
