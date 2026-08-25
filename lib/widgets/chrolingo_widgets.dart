import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Небольшая библиотека переиспользуемых виджетов Chrolingo, задающих общий
/// язык макетов Chrolingo (.panel/.pill/.tabbar/.menu-row/...).
/// Полноценный иллюстрированный аватар-конструктор из макета (экран 03) в
/// это MVP не входит — вместо лицевых SVG используется простой круглый
/// плейсхолдер с той же системой рамок/свечения по цвету лиги/редкости.

class ChPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;
  final List<BoxShadow>? boxShadow;

  const ChPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.borderColor,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.navy3.withValues(alpha: 0.5),
            AppColors.navy1.withValues(alpha: 0.5),
          ],
        ),
        border: Border.all(color: borderColor ?? AppColors.line),
        borderRadius: BorderRadius.circular(14),
        boxShadow: boxShadow,
      ),
      child: child,
    );
  }
}

class ChPill extends StatelessWidget {
  final Widget icon;
  final String label;

  const ChPill({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.navy3,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 5),
          Text(label, style: AppFonts.mono(fontSize: 11, weight: FontWeight.w700, color: AppColors.cream)),
        ],
      ),
    );
  }
}

class ChTabBar extends StatelessWidget {
  final List<String> tabs;
  final int selected;
  final ValueChanged<int> onChanged;

  const ChTabBar({super.key, required this.tabs, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.navy1,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: List.generate(tabs.length, (i) {
          final active = i == selected;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  gradient: active
                      ? const LinearGradient(colors: [AppColors.gold, AppColors.gold2], begin: Alignment.topCenter, end: Alignment.bottomCenter)
                      : null,
                ),
                child: Text(
                  tabs[i],
                  textAlign: TextAlign.center,
                  style: AppFonts.ui(
                    fontSize: 11,
                    weight: FontWeight.w700,
                    color: active ? Colors.black : AppColors.muted,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class ChMenuRow extends StatelessWidget {
  final Widget icon;
  final String title;
  final bool flagship;
  final VoidCallback onTap;

  const ChMenuRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.flagship = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: flagship ? AppColors.gold : AppColors.line, width: 1.5),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: flagship
                ? [AppColors.goldSoft, AppColors.navy1.withValues(alpha: 0.55)]
                : [AppColors.navy3.withValues(alpha: 0.55), AppColors.navy1.withValues(alpha: 0.55)],
          ),
          boxShadow: flagship
              ? [BoxShadow(color: AppColors.gold.withValues(alpha: 0.24), blurRadius: 18)]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                icon,
                const SizedBox(width: 11),
                Text(title, style: AppFonts.ui(fontSize: 16, color: flagship ? AppColors.gold : AppColors.cream)),
              ],
            ),
            Icon(Icons.chevron_right, color: flagship ? AppColors.gold : AppColors.muted),
          ],
        ),
      ),
    );
  }
}

class ChModeIcon extends StatelessWidget {
  final IconData icon;
  final List<Color> gradient;

  const ChModeIcon({super.key, required this.icon, required this.gradient});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: LinearGradient(colors: gradient, begin: Alignment.topLeft, end: Alignment.bottomRight),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 3))],
      ),
      child: Icon(icon, size: 16, color: Colors.black87),
    );
  }
}

/// Плейсхолдер аватара — цветной круг с инициалом вместо иллюстрированного
/// лица из макета (свой конструктор лиц — отдельная задача, не в этом MVP).
class ChAvatar extends StatelessWidget {
  final String name;
  final double size;
  final Color ringColor;
  final bool online;

  const ChAvatar({
    super.key,
    required this.name,
    this.size = 40,
    this.ringColor = AppColors.lineStrong,
    this.online = false,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [AppColors.navy4, AppColors.navy2]),
              boxShadow: [BoxShadow(color: ringColor, blurRadius: size * 0.3, spreadRadius: size * 0.045)],
              border: Border.all(color: ringColor, width: 2),
            ),
            child: Center(
              child: Text(
                initial,
                style: AppFonts.ui(fontSize: size * 0.4, weight: FontWeight.w800, color: AppColors.cream),
              ),
            ),
          ),
          if (online)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: size * 0.24,
                height: size * 0.24,
                decoration: BoxDecoration(
                  color: AppColors.ok,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.navy1, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ChItemSlot extends StatelessWidget {
  final Widget preview;
  final String title;
  final Widget? priceTag;
  final bool owned;
  final VoidCallback? onTap;

  const ChItemSlot({
    super.key,
    required this.preview,
    required this.title,
    this.priceTag,
    this.owned = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: owned ? AppColors.gold : AppColors.line, width: 1.5),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.navy3.withValues(alpha: 0.5), AppColors.navy1.withValues(alpha: 0.5)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            preview,
            const SizedBox(height: 7),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.ui(fontSize: 10, color: AppColors.cream),
            ),
            if (priceTag != null) ...[const SizedBox(height: 5), priceTag!],
          ],
        ),
      ),
    );
  }
}

/// Статичная «волна» — визуальная метка голосового сообщения. Реальная
/// огибающая амплитуд потребовала бы разбора аудиофайла на клиенте, что для
/// ленты сообщений избыточно.
class ChWaveform extends StatelessWidget {
  final double width;
  final Color color;

  const ChWaveform({super.key, required this.width, required this.color});

  static const _bars = [4.0, 9.0, 15.0, 7.0, 18.0, 11.0, 6.0, 14.0, 8.0, 16.0, 5.0, 10.0, 13.0, 6.0];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: _bars
            .map((h) => Container(
                  width: 2.5,
                  height: h,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ))
            .toList(),
      ),
    );
  }
}
