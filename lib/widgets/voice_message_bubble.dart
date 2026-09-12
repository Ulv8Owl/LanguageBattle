import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../core/supabase_client.dart';
import '../core/theme.dart';
import 'ai_avatar.dart';
import 'chrolingo_widgets.dart';

/// Отправленное голосовое в ленте — как в мессенджере: аватар, кнопка
/// воспроизведения, дорожка и (в бою) балл за раунд.
///
/// Один и тот же виджет во всех трёх режимах: в Состязании и Дуэли
/// соперники слушают голосовые друг друга, в Одиночной Игре игрок
/// переслушивает свои. Бакет приватный, поэтому ссылка каждый раз
/// подписывается заново — RLS-политика хранилища сама решает, кому файл
/// доступен (участникам матча и владельцу соло-сессии).
class VoiceMessageBubble extends StatefulWidget {
  final String audioStoragePath;
  final String name;

  /// Аватар говорящего. Пусто — кружок с инициалом, как раньше.
  final Map<String, String> avatar;

  /// true — голосовое соперника: пузырь уходит вправо и красится в другой
  /// акцент, как входящее сообщение.
  final bool alignRight;

  /// Почему это голосовое сейчас не слушается. null — слушается.
  ///
  /// ЗАЧЕМ ЗАПРЕТ. Чужой ответ в бою — это готовый перевод той же фразы.
  /// Послушав его до своего ответа, игрок переводит не задание, а речь
  /// соперника, и раунд превращается в диктант. Кнопка при этом остаётся
  /// на месте и гаснет: спрятать её значило бы, что сообщения соперника
  /// то появляются, то исчезают.
  final String? lockedReason;

  /// Тап по аватарке — карточка игрока. null — аватарка не нажимается.
  final VoidCallback? onAvatarTap;

  /// Балл за это голосовое, если он предусмотрен и уже выставлен.
  ///
  /// В бою балла здесь больше нет: он и разбор приходят отдельным
  /// сообщением ниже, как в Одиночной Игре. Значок на самом пузыре не
  /// оставлял места разбору, а индикатор на нём читался как «голосовое
  /// ещё грузится», хотя грузилась оценка.
  final int? score;

  const VoiceMessageBubble({
    super.key,
    required this.audioStoragePath,
    required this.name,
    this.avatar = const {},
    required this.alignRight,
    this.score,
    this.lockedReason,
    this.onAvatarTap,
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  final _player = AudioPlayer();
  bool _isPlaying = false;
  bool _loadingUrl = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    final locked = widget.lockedReason;
    if (locked != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(locked)));
      return;
    }
    if (_isPlaying) {
      await _player.stop();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }
    setState(() => _loadingUrl = true);
    try {
      final url = await supabase.storage
          .from('voice-recordings')
          .createSignedUrl(widget.audioStoragePath, 3600);
      await _player.play(UrlSource(url));
      if (!mounted) return;
      setState(() {
        _isPlaying = true;
        _loadingUrl = false;
      });
      _player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _isPlaying = false);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingUrl = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось воспроизвести: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Золотом светится СВОЁ голосовое (оно справа), соперник — холодным
    // акцентом. Было наоборот: подсвечивался чужой ответ, и в ленте
    // взгляд цеплялся не за то.
    final accent = widget.alignRight ? AppColors.gold : AppColors.cyan;
    // Закрытое голосовое видно, но тускло: игрок должен понимать, что
    // соперник ответил, и при этом не иметь соблазна нажать.
    final locked = widget.lockedReason != null;
    final iconColor = locked ? AppColors.muted : accent;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: widget.alignRight ? AppColors.gold.withValues(alpha: 0.14) : AppColors.navy3,
        border: Border.all(color: accent.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _loadingUrl ? null : _togglePlay,
            child: _loadingUrl
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(
                    locked
                        ? Icons.lock_outline
                        : (_isPlaying ? Icons.stop : Icons.play_arrow),
                    color: iconColor,
                    size: 22,
                  ),
          ),
          const SizedBox(width: 8),
          ChWaveform(width: 96, color: iconColor),
          if (widget.score != null) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(7)),
              child: Text(
                '${widget.score}',
                style: AppFonts.ui(fontSize: 12, weight: FontWeight.w800, color: Colors.black),
              ),
            ),
          ],
        ],
      ),
    );

    final Widget avatar = GestureDetector(
      onTap: widget.onAvatarTap,
      behavior: HitTestBehavior.opaque,
      child: ChAvatar(
          name: widget.name,
          avatar: widget.avatar,
          size: avatarSize,
          ringColor: accent.withValues(alpha: 0.6)),
    );

    return Padding(
      // Одинаковый вертикальный ритм со всеми остальными сообщениями ленты:
      // раньше у голосовых и текстовых отступы отличались, и промежутки
      // между соседними сообщениями получались разной величины.
      padding: const EdgeInsets.symmetric(vertical: feedGap / 2),
      child: Row(
        mainAxisAlignment: widget.alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: widget.alignRight
            ? [Flexible(child: bubble), const SizedBox(width: 8), avatar]
            : [avatar, const SizedBox(width: 8), Flexible(child: bubble)],
      ),
    );
  }
}
