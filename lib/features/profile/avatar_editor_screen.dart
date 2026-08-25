import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/nav_state.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Редактор аватара (раздел 5.1, п.4): крупное превью лица анфас, категории
/// вкладками, сетка вариантов снизу — часть открыта, часть заблокирована
/// ценой и ведёт в Магазин.
///
/// Лицо собирается из простых геометрических слоёв, а не из иллюстраций:
/// набор рисованных вариантов — отдельная задача для художника, и подменять
/// её выдуманными картинками здесь было бы враньём про готовность.
class AvatarEditorScreen extends StatefulWidget {
  const AvatarEditorScreen({super.key});

  @override
  State<AvatarEditorScreen> createState() => _AvatarEditorScreenState();
}

class _AvatarEditorScreenState extends State<AvatarEditorScreen> {
  static const _tabs = ['Причёска', 'Брови', 'Глаза', 'Губы', 'Уши'];
  static const _slots = ['hair', 'brows', 'eyes', 'lips', 'ears'];

  int _tab = 0;
  bool _loading = true;
  bool _saving = false;

  List<Map<String, dynamic>> _items = [];
  Set<String> _owned = {};

  /// Слот -> id выбранного предмета. Локальная копия users.equipped_avatar,
  /// применяется целиком по кнопке подтверждения.
  Map<String, String> _equipped = {};
  Map<String, String> _initial = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = currentUserId;
    try {
      final items = await supabase
          .from('cosmetic_items')
          .select()
          .eq('type', 'avatar_skin')
          .order('price_soft');
      final inventory = await supabase.from('user_inventory').select('item_id').eq('user_id', uid);
      final profile = await supabase.from('users').select('equipped_avatar').eq('id', uid).maybeSingle();

      final equippedRaw = profile?['equipped_avatar'];
      final equipped = <String, String>{};
      if (equippedRaw is Map) {
        equippedRaw.forEach((k, v) {
          if (v is String) equipped[k as String] = v;
        });
      }

      if (!mounted) return;
      setState(() {
        _items = List<Map<String, dynamic>>.from(items);
        _owned = inventory.map((r) => r['item_id'] as String).toSet();
        _equipped = equipped;
        _initial = Map<String, String>.from(equipped);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось загрузить аватар: $e')),
      );
    }
  }

  Future<void> _confirm() async {
    setState(() => _saving = true);
    try {
      // Экипируется только то, что реально изменилось.
      for (final entry in _equipped.entries) {
        if (_initial[entry.key] == entry.value) continue;
        await supabase.rpc('equip_item', params: {'p_item_id': entry.value});
      }
      if (!mounted) return;
      _initial = Map<String, String>.from(_equipped);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Аватар сохранён')));
      if (context.canPop()) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _onTapVariant(Map<String, dynamic> item) {
    final id = item['id'] as String;
    if (!_owned.contains(id)) {
      // Заблокированный вариант ведёт в Магазин (раздел 5.1, п.4).
      shopSectionRequest.value = ShopSections.items;
      arenaTabRequest.value = ArenaTabs.shop;
      if (context.canPop()) context.pop();
      return;
    }
    setState(() => _equipped[_slots[_tab]] = id);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final slot = _slots[_tab];
    final variants = _items.where((i) => i['avatar_slot'] == slot).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Аватар'),
        actions: [
          IconButton(
            onPressed: _saving ? null : _confirm,
            icon: _saving
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check, color: AppColors.gold),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            _FacePreview(equipped: _equipped),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ChTabBar(tabs: _tabs, selected: _tab, onChanged: (i) => setState(() => _tab = i)),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: variants.isEmpty
                  ? const Center(
                      child: Text('Для этой категории вариантов пока нет',
                          style: TextStyle(color: AppColors.muted, fontSize: 12)),
                    )
                  : GridView.count(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      crossAxisCount: 3,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.85,
                      children: variants.map(_buildVariant).toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVariant(Map<String, dynamic> item) {
    final id = item['id'] as String;
    final owned = _owned.contains(id);
    final selected = _equipped[_slots[_tab]] == id;
    final exclusive = item['subscriber_exclusive'] as bool? ?? false;
    final price = item['price_soft'] as int?;

    return ChItemSlot(
      owned: selected,
      preview: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.face_retouching_natural,
            size: 30,
            color: owned ? AppColors.cream : AppColors.muted,
          ),
          if (!owned)
            const Positioned(
              right: 0,
              top: 0,
              child: Icon(Icons.lock, size: 12, color: AppColors.gold),
            ),
        ],
      ),
      title: (item['name'] as String?) ?? '',
      priceTag: owned
          ? Text(selected ? 'Надето' : 'Открыто', style: AppFonts.mono(fontSize: 9, color: AppColors.ok))
          : exclusive
              ? Text('★ Подписка',
                  style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.gold))
              : ChPill(
                  icon: const Icon(Icons.circle, size: 9, color: AppColors.gold),
                  label: '${price ?? 0}',
                ),
      onTap: () => _onTapVariant(item),
    );
  }
}

/// Превью лица анфас. Части, которые игрок выбрал, подсвечиваются золотом —
/// это условная схема, а не финальная иллюстрация (см. комментарий к экрану).
class _FacePreview extends StatelessWidget {
  final Map<String, String> equipped;

  const _FacePreview({required this.equipped});

  bool _has(String slot) => equipped.containsKey(slot);

  Color _tint(String slot) => _has(slot) ? AppColors.gold : AppColors.lineStrong;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        height: 168,
        width: 168,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.navy4, AppColors.navy2],
          ),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.5), width: 2),
          boxShadow: [BoxShadow(color: AppColors.gold.withValues(alpha: 0.18), blurRadius: 28)],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Причёска
            Positioned(
              top: 18,
              child: Container(
                height: 26,
                width: 96,
                decoration: BoxDecoration(
                  color: _tint('hair'),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
                ),
              ),
            ),
            // Уши
            Positioned(
              left: 22,
              child: _Ear(color: _tint('ears')),
            ),
            Positioned(
              right: 22,
              child: _Ear(color: _tint('ears')),
            ),
            // Брови
            Positioned(
              top: 62,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Bar(color: _tint('brows'), width: 26, height: 5),
                  const SizedBox(width: 18),
                  _Bar(color: _tint('brows'), width: 26, height: 5),
                ],
              ),
            ),
            // Глаза
            Positioned(
              top: 78,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Eye(color: _tint('eyes')),
                  const SizedBox(width: 18),
                  _Eye(color: _tint('eyes')),
                ],
              ),
            ),
            // Губы
            Positioned(
              bottom: 42,
              child: _Bar(color: _tint('lips'), width: 38, height: 8),
            ),
          ],
        ),
      ),
    );
  }
}

class _Ear extends StatelessWidget {
  final Color color;

  const _Ear({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      width: 14,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
    );
  }
}

class _Eye extends StatelessWidget {
  final Color color;

  const _Eye({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 14,
      width: 22,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
    );
  }
}

class _Bar extends StatelessWidget {
  final Color color;
  final double width;
  final double height;

  const _Bar({required this.color, required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
    );
  }
}
