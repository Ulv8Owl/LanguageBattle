import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/game_access.dart';
import '../../core/leagues.dart';
import '../../core/nav_state.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../core/word_packs.dart';
import '../../widgets/chrolingo_widgets.dart';
import '../../widgets/trial_countdown_banner.dart';

/// Магазин — три раздела: «Подписка» (карточка тарифа, оформление —
/// заглушка без платёжного шлюза), «Предметы» (сетка косметики 3×4 со
/// скроллом и фильтром по категориям) и «Наборы слов» (паки по 100 слов
/// для Тренировки, по 10 на лигу — открываются по мере роста рейтинга).
class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  int _section = ShopSections.subscription;
  int _category = 0;

  WalletState _wallet = WalletState.empty;
  List<Map<String, dynamic>> _items = [];
  Set<String> _owned = {};
  List<WordPackInfo> _wordPacks = [];
  bool _loading = true;
  bool _activating = false;
  int? _buyingWordPack;

  /// Фильтр по категориям: Рамки / Эмоции / Аватар.
  static const _categories = ['Рамки', 'Эмоции', 'Аватар'];
  static const _categoryTypes = ['profile_frame', 'emote', 'avatar_skin'];

  @override
  void initState() {
    super.initState();
    shopSectionRequest.addListener(_onSectionRequested);
    _section = shopSectionRequest.value;
    _load();
  }

  @override
  void dispose() {
    shopSectionRequest.removeListener(_onSectionRequested);
    super.dispose();
  }

  void _onSectionRequested() {
    if (!mounted) return;
    setState(() => _section = shopSectionRequest.value);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final wallet = await GameAccess.sync();
      final items = await supabase.from('cosmetic_items').select().order('type').order('price_soft');
      final inventory = await supabase.from('user_inventory').select('item_id').eq('user_id', currentUserId);
      final wordPacks = await WordPackCatalog.fetch();
      if (!mounted) return;
      setState(() {
        _wallet = wallet;
        _items = List<Map<String, dynamic>>.from(items);
        _owned = inventory.map((r) => r['item_id'] as String).toSet();
        _wordPacks = wordPacks;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('Не удалось загрузить магазин: $e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Оформление подписки — ЗАГЛУШКА: статус становится 'active' сразу,
  /// без реального платёжного шлюза (Google Play Billing подключается
  /// отдельной задачей).
  Future<void> _subscribe() async {
    setState(() => _activating = true);
    try {
      await GameAccess.activateSubscription();
      await _load();
      _toast('Подписка активна');
    } catch (e) {
      _toast('Не удалось оформить подписку: $e');
    } finally {
      if (mounted) setState(() => _activating = false);
    }
  }

  Future<void> _buy(Map<String, dynamic> item) async {
    try {
      await supabase.rpc('purchase_item', params: {'p_item_id': item['id']});
      await _load();
      _toast('Куплено: ${item['name']}');
    } catch (e) {
      if (ServerErrors.isSubscriptionRequired(e)) {
        _toast('Этот предмет доступен только по подписке');
        setState(() => _section = ShopSections.subscription);
      } else if (ServerErrors.isInsufficientFunds(e)) {
        _toast('Не хватает монет');
      } else {
        _toast('Не удалось купить: $e');
      }
    }
  }

  Future<void> _buyWordPack(WordPackInfo pack) async {
    final key = pack.levelIndex * 10 + pack.packIndex;
    setState(() => _buyingWordPack = key);
    try {
      await WordPackCatalog.purchase(pack.levelIndex, pack.packIndex);
      notifyWordPacksChanged();
      await _load();
      _toast('Куплено: слова ${pack.rangeLabel}');
    } catch (e) {
      if (ServerErrors.isInsufficientFunds(e)) {
        _toast('Не хватает монет');
      } else if (ServerErrors.isLeagueLocked(e)) {
        _toast('Сначала поднимись до этой лиги');
      } else {
        _toast('Не удалось купить: $e');
      }
    } finally {
      if (mounted) setState(() => _buyingWordPack = null);
    }
  }

  Future<void> _equip(Map<String, dynamic> item) async {
    try {
      await supabase.rpc('equip_item', params: {'p_item_id': item['id']});
      _toast('Экипировано: ${item['name']}');
    } catch (e) {
      _toast('Не удалось экипировать: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Магазин', style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800)),
              const Spacer(),
              ChPill(
                icon: const Icon(Icons.bolt, size: 12, color: AppColors.cyan),
                label: '${_wallet.energyCurrent}/${_wallet.energyMax}',
              ),
              const SizedBox(width: 6),
              ChPill(
                icon: const Icon(Icons.circle, size: 12, color: AppColors.gold),
                label: '${_wallet.coins}',
              ),
            ],
          ),
          const SizedBox(height: 14),
          ChTabBar(
            tabs: const ['Подписка', 'Предметы', 'Слова'],
            selected: _section,
            onChanged: (i) => setState(() => _section = i),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: switch (_section) {
              ShopSections.subscription => _buildSubscription(),
              ShopSections.items => _buildItems(),
              _ => _buildWordPacks(),
            },
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // Раздел «Подписка»
  // -------------------------------------------------------------------

  Widget _buildSubscription() {
    // Числовой формат нарочно: локализованные названия месяцев требуют
    // initializeDateFormatting, а локализации интерфейса в проекте пока нет.
    final dateFormat = DateFormat('dd.MM.yyyy');
    final subscribed = _wallet.isSubscribed;
    final trial = _wallet.isTrial;

    String headline;
    String? subline;
    String buttonLabel;
    if (subscribed) {
      headline = 'Подписка активна';
      subline = _wallet.expiresAt == null
          ? null
          : 'Действует до ${dateFormat.format(_wallet.expiresAt!.toLocal())}';
      buttonLabel = 'Продлить';
    } else if (trial) {
      headline = 'Пробный период';
      subline = null;
      buttonLabel = 'Оформить';
    } else {
      headline = 'Пробный период закончился';
      subline = 'Оформи подписку, чтобы снова играть в режимах с ИИ.';
      buttonLabel = 'Оформить';
    }

    return ListView(
      children: [
        ChPanel(
          borderColor: AppColors.gold,
          boxShadow: [BoxShadow(color: AppColors.gold.withValues(alpha: 0.16), blurRadius: 22)],
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('CHROLINGO PRO',
                  style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold)),
              const SizedBox(height: 10),
              Text(headline, style: AppFonts.ui(fontSize: 17, weight: FontWeight.w800)),
              if (subline != null) ...[
                const SizedBox(height: 6),
                Text(subline, style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.45)),
              ],
              if (trial && _wallet.trialEndsAt != null) ...[
                const SizedBox(height: 12),
                TrialCountdownBanner(trialEndsAt: _wallet.trialEndsAt!),
              ],
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('399 ₽', style: AppFonts.ui(fontSize: 26, weight: FontWeight.w800, color: AppColors.gold)),
                  const SizedBox(width: 6),
                  const Text('в месяц', style: TextStyle(color: AppColors.muted, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 14),
              const _Perk('Косметика с меткой «★ Подписка»'),
              const SizedBox(height: 7),
              const _Perk('Подписочная ветка наград Battle Pass'),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _activating ? null : _subscribe,
                  child: _activating
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                        )
                      : Text(buttonLabel),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ChPanel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.lock_outline, size: 14, color: AppColors.danger),
                  const SizedBox(width: 6),
                  Text('БЕЗ ПОДПИСКИ ЗАКРЫВАЮТСЯ',
                      style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.danger)),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Одиночная Игра, Состязание и Дуэль — режимы с подключённым ИИ.',
                style: TextStyle(color: AppColors.cream, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.check_circle_outline, size: 14, color: AppColors.ok),
                  const SizedBox(width: 6),
                  Text('ОСТАЁТСЯ ДОСТУПНА',
                      style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.ok)),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Тренировка (карточки со словами) — она не использует ИИ и '
                'играется всегда, с подпиской или без.',
                style: TextStyle(color: AppColors.cream, fontSize: 12, height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Энергия к подписке не привязана: лимит попыток в Одиночной Игре '
          'действует всегда и восстанавливается со временем.',
          style: AppFonts.mono(fontSize: 10, color: AppColors.muted).copyWith(height: 1.5),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------
  // Раздел «Наборы слов» — 6 лиг × 10 паков по 100 слов для Тренировки.
  // -------------------------------------------------------------------

  Widget _buildWordPacks() {
    return ListView.builder(
      itemCount: leagueBands.length,
      itemBuilder: (context, levelIndex) {
        final league = leagueBands[levelIndex];
        final packs = _wordPacks.where((p) => p.levelIndex == levelIndex).toList()
          ..sort((a, b) => a.packIndex.compareTo(b.packIndex));
        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.emoji_events, size: 14, color: league.color),
                  const SizedBox(width: 6),
                  Text(league.shortName, style: AppFonts.ui(fontSize: 13, weight: FontWeight.w800, color: league.color)),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: packs.map((p) => _WordPackTile(
                  pack: p,
                  busy: _buyingWordPack == levelIndex * 10 + p.packIndex,
                  onTap: p.owned ? null : () => _buyWordPack(p),
                )).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------
  // Раздел «Предметы»
  // -------------------------------------------------------------------

  Widget _buildItems() {
    final type = _categoryTypes[_category];
    final visible = _items.where((i) => i['type'] == type).toList();

    return Column(
      children: [
        ChTabBar(
          tabs: _categories,
          selected: _category,
          onChanged: (i) => setState(() => _category = i),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: visible.isEmpty
              ? const Center(
                  child: Text('В этой категории пока пусто', style: TextStyle(color: AppColors.muted, fontSize: 12)),
                )
              // Сетка 3 в ширину × 4 в высоту видимых одновременно; всё, что
              // не помещается, уходит в скролл (предметов будет много).
              : LayoutBuilder(
                  builder: (context, constraints) {
                    const spacing = 10.0;
                    final tileWidth = (constraints.maxWidth - spacing * 2) / 3;
                    final tileHeight = (constraints.maxHeight - spacing * 3) / 4;
                    return GridView.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: spacing,
                        crossAxisSpacing: spacing,
                        childAspectRatio: tileWidth / tileHeight.clamp(90.0, 220.0),
                      ),
                      itemCount: visible.length,
                      itemBuilder: (context, i) => _buildTile(visible[i]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTile(Map<String, dynamic> item) {
    final owned = _owned.contains(item['id']);
    final exclusive = item['subscriber_exclusive'] as bool? ?? false;
    final priceSoft = item['price_soft'] as int?;

    Widget priceTag;
    if (owned) {
      priceTag = Text('Куплено', style: AppFonts.mono(fontSize: 9, color: AppColors.ok));
    } else if (exclusive) {
      priceTag = Text(
        '★ Подписка',
        style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold),
      );
    } else {
      priceTag = ChPill(
        icon: const Icon(Icons.circle, size: 9, color: AppColors.gold),
        label: '${priceSoft ?? 0}',
      );
    }

    return ChItemSlot(
      owned: owned,
      preview: Icon(_iconFor(item['type'] as String?), size: 30, color: exclusive ? AppColors.gold : AppColors.cream),
      title: (item['name'] as String?) ?? '',
      priceTag: priceTag,
      onTap: () => owned ? _equip(item) : _buy(item),
    );
  }

  static IconData _iconFor(String? type) {
    switch (type) {
      case 'emote':
        return Icons.emoji_emotions;
      case 'avatar_skin':
        return Icons.face_retouching_natural;
      default:
        return Icons.circle_outlined;
    }
  }
}

class _WordPackTile extends StatelessWidget {
  final WordPackInfo pack;
  final bool busy;
  final VoidCallback? onTap;

  const _WordPackTile({required this.pack, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final locked = pack.leagueLocked;
    Widget trailing;
    if (busy) {
      trailing = const SizedBox(height: 12, width: 12, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (pack.owned) {
      trailing = const Icon(Icons.check_circle, size: 14, color: AppColors.ok);
    } else if (locked) {
      trailing = const Icon(Icons.lock_outline, size: 14, color: AppColors.muted);
    } else {
      trailing = ChPill(
        icon: const Icon(Icons.circle, size: 9, color: AppColors.gold),
        label: '${pack.price}',
      );
    }

    return InkWell(
      onTap: locked || pack.owned || busy ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: pack.owned ? AppColors.ok : AppColors.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              pack.rangeLabel,
              style: AppFonts.mono(
                fontSize: 11,
                weight: FontWeight.w700,
                color: locked ? AppColors.muted : AppColors.cream,
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _Perk extends StatelessWidget {
  final String text;

  const _Perk(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check, size: 15, color: AppColors.ok),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12, color: AppColors.cream, height: 1.4)),
        ),
      ],
    );
  }
}
