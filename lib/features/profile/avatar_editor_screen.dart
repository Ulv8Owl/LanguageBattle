import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/avatar_parts.dart';
import '../../widgets/avatar_portrait.dart';

/// Редактор аватара: крупное превью и ряды вариантов по частям лица.
///
/// СОБИРАЕТСЯ ИЗ СПРАЙТОВ, а не из геометрических фигур, как было раньше.
/// Прежний экран рисовал условную схему — прямоугольник вместо причёски,
/// овал вместо глаза — и честно про это писал: рисованных вариантов не
/// существовало. Теперь они есть (assets/avatar), и превью показывает ровно
/// то, что игрок увидит в игре: тот же виджет, те же слои.
///
/// ВСЕ ЧАСТИ БЕСПЛАТНЫ. Стартовый набор небольшой, и продавать из него
/// половину значило бы оставить игрока с лицом без глаз до первой покупки.
/// Платные части — отдельная задача, и начнётся она с рисунков, а не с
/// прайса.
class AvatarEditorScreen extends StatefulWidget {
  const AvatarEditorScreen({super.key});

  @override
  State<AvatarEditorScreen> createState() => _AvatarEditorScreenState();
}

class _AvatarEditorScreenState extends State<AvatarEditorScreen> {
  bool _loading = true;
  bool _saving = false;

  /// Слот -> вариант. Локальная копия users.equipped_avatar: применяется
  /// целиком по галочке, чтобы примерка не сохранялась сама собой.
  Map<String, String> _equipped = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await supabase
          .from('users')
          .select('equipped_avatar')
          .eq('id', currentUserId)
          .maybeSingle();
      final saved = avatarFromJson(profile?['equipped_avatar']);
      if (!mounted) return;
      setState(() {
        // Пустой редактор показывал бы один фон, и было бы непонятно,
        // собирается ли тут вообще что-нибудь.
        _equipped = hasAvatar(saved) ? saved : defaultAvatar();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _equipped = defaultAvatar();
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось загрузить аватар: $e')),
      );
    }
  }

  Future<void> _confirm() async {
    setState(() => _saving = true);
    try {
      // Прямая запись в свою строку: политика users разрешает владельцу
      // менять свой профиль (миграция 0002), и отдельная RPC добавила бы
      // ещё одно место, где список слотов должен совпадать с каталогом.
      await supabase
          .from('users')
          .update({'equipped_avatar': _equipped})
          .eq('id', currentUserId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Аватар сохранён')),
      );
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

  void _choose(AvatarSlot slot, String? partId) {
    setState(() {
      if (partId == null) {
        _equipped.remove(slot.id);
      } else {
        _equipped[slot.id] = partId;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Аватар'),
        actions: [
          IconButton(
            tooltip: 'Сохранить',
            onPressed: _saving ? null : _confirm,
            icon: _saving
                ? const SizedBox(
                    height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check, color: AppColors.gold),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Center(child: _Preview(equipped: _equipped)),
            const SizedBox(height: 20),
            for (final slot in avatarSlots) ...[
              _SlotRow(
                slot: slot,
                chosen: _equipped[slot.id],
                onChoose: (id) => _choose(slot, id),
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

/// Превью — тот же виджет, что рисует аватар в игре.
///
/// Именно тот же, а не похожий: собственная отрисовка предпросмотра рано
/// или поздно разошлась бы с настоящей, и игрок сохранял бы одно, а видел
/// другое.
class _Preview extends StatelessWidget {
  final Map<String, String> equipped;

  const _Preview({required this.equipped});

  @override
  Widget build(BuildContext context) {
    // Рамка поверх портрета, а не вокруг него: в BoxDecoration она создаёт
    // отступ, и между картинкой и кольцом оставалась полоска подложки.
    return SizedBox(
      height: 168,
      width: 168,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: AppColors.gold.withValues(alpha: 0.18), blurRadius: 28),
                ],
              ),
              child: ClipOval(child: AvatarPortrait(avatar: equipped)),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.gold.withValues(alpha: 0.5), width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Одна часть лица: заголовок и ряд вариантов.
///
/// Ряд, а не сетка со вкладками: вариантов пока по одному-два на слот, и
/// вкладки прятали бы их друг от друга без всякой нужды — всё лицо
/// помещается на один экран.
class _SlotRow extends StatelessWidget {
  final AvatarSlot slot;
  final String? chosen;
  final ValueChanged<String?> onChoose;

  const _SlotRow({required this.slot, required this.chosen, required this.onChoose});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          slot.title,
          style: AppFonts.mono(fontSize: 9, weight: FontWeight.w700, color: AppColors.muted),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 76,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              // «Без» — только там, где лицо без этой части остаётся лицом.
              if (slot.optional)
                _Variant(
                  label: 'Без',
                  selected: chosen == null,
                  onTap: () => onChoose(null),
                  layers: const [],
                ),
              for (final part in slot.parts)
                _Variant(
                  label: part.title,
                  selected: chosen == part.id,
                  onTap: () => onChoose(part.id),
                  layers: part.layers,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Плитка варианта: сам спрайт, а не иконка.
///
/// Иконка «лицо» на всех вариантах разом — это то, что было раньше: выбрать
/// глаза, не видя глаз, невозможно.
class _Variant extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final List<String> layers;

  const _Variant({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.layers,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 52,
              width: 52,
              decoration: BoxDecoration(
                color: AppColors.navy3,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? AppColors.gold : AppColors.line,
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: layers.isEmpty
                  ? const Icon(Icons.block, size: 18, color: AppColors.muted)
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        for (final layer in layers)
                          Image.asset(
                            layer,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.none,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 5),
            SizedBox(
              width: 56,
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.ui(
                  fontSize: 10,
                  color: selected ? AppColors.gold : AppColors.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
