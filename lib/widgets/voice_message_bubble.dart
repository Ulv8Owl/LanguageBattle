import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../core/supabase_client.dart';
import '../core/theme.dart';
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

  /// true — голосовое соперника: пузырь уходит вправо и красится в другой
  /// акцент, как входящее сообщение.
  final bool alignRight;

  /// Балл за это голосовое, если он предусмотрен и уже выставлен.
  final int? score;

  /// true — балл за это голосовое будет, но его ещё считают: на его месте
  /// крутится индикатор. false — балла тут не бывает вовсе (родной слот
  /// Дуэли, попытка №1 в соло).
  final bool scorePending;

  const VoiceMessageBubble({
    super.key,
    required this.audioStoragePath,
    required this.name,
    required this.alignRight,
    this.score,
    this.scorePending = false,
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
    final accent = widget.alignRight ? AppColors.cyan : AppColors.gold;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: widget.alignRight ? AppColors.navy3 : AppColors.gold.withValues(alpha: 0.14),
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
                : Icon(_isPlaying ? Icons.stop : Icons.play_arrow, color: accent, size: 22),
          ),
          const SizedBox(width: 8),
          ChWaveform(width: 96, color: accent),
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
          ] else if (widget.scorePending) ...[
            const SizedBox(width: 10),
            const SizedBox(
              height: 12,
              width: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: AppColors.muted),
            ),
          ],
        ],
      ),
    );

    final avatar = ChAvatar(name: widget.name, size: 28, ringColor: accent.withValues(alpha: 0.6));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
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
