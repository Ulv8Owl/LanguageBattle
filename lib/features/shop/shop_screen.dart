import 'package:flutter/material.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../widgets/lexarena_widgets.dart';

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  int _tab = 0;
  Map<String, dynamic>? _wallet;
  List<Map<String, dynamic>> _items = [];
  Set<String> _owned = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final uid = currentUserId;
    try {
      final wallet = await supabase.from('currency_wallets').select().eq('user_id', uid).maybeSingle();
      final items = await supabase.from('cosmetic_items').select();
      final inventory = await supabase.from('user_inventory').select('item_id').eq('user_id', uid);
      if (!mounted) return;
      setState(() {
        _wallet = wallet;
        _items = List<Map<String, dynamic>>.from(items);
        _owned = inventory.map((r) => r['item_id'] as String).toSet();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _buy(Map<String, dynamic> item) async {
    try {
      await supabase.rpc('purchase_item', params: {'p_item_id': item['id']});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Куплено: ${item['name']}')));
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось купить: $e')));
      }
    }
  }

  Future<void> _equip(Map<String, dynamic> item) async {
    try {
      await supabase.rpc('equip_item', params: {'p_item_id': item['id']});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Экипировано: ${item['name']}')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось экипировать: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final typeForTab = ['profile_frame', 'emote', null][_tab];
    final visible = typeForTab == null ? <Map<String, dynamic>>[] : _items.where((i) => i['type'] == typeForTab).toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Магазин', style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800)),
              const Spacer(),
              LxPill(icon: const Icon(Icons.diamond, size: 12, color: AppColors.cream), label: '${_wallet?['hard_currency'] ?? 0}'),
              const SizedBox(width: 6),
              LxPill(icon: const Icon(Icons.circle, size: 12, color: AppColors.gold), label: '${_wallet?['soft_currency'] ?? 0}'),
            ],
          ),
          const SizedBox(height: 14),
          LxTabBar(
            tabs: const ['Рамки', 'Эмоции', 'Внешность'],
            selected: _tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: typeForTab == null
                ? const Center(
                    child: Text(
                      'Конструктор внешности — отдельная большая задача\n(парametric-редактор лица), не входит в это MVP.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  )
                : GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.95,
                    children: visible.map((item) {
                      final owned = _owned.contains(item['id']);
                      final priceSoft = item['price_soft'] as int?;
                      final priceHard = item['price_hard'] as int?;
                      return LxItemSlot(
                        owned: owned,
                        preview: Icon(
                          item['type'] == 'emote' ? Icons.emoji_emotions : Icons.circle_outlined,
                          size: 36,
                          color: AppColors.gold,
                        ),
                        title: (item['name'] as String?) ?? '',
                        priceTag: owned
                            ? const Text('Куплено', style: TextStyle(color: AppColors.ok, fontSize: 10))
                            : LxPill(
                                icon: Icon(priceHard != null ? Icons.diamond : Icons.circle, size: 10, color: priceHard != null ? AppColors.cream : AppColors.gold),
                                label: '${priceHard ?? priceSoft ?? 0}',
                              ),
                        onTap: () => owned ? _equip(item) : _buy(item),
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}
