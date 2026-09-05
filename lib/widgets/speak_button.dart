import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/speech_playback.dart';

/// Значок динамика: «послушать, как это должно звучать».
///
/// Стоит рядом с исправленной фразой во всех трёх режимах. Письменная
/// правка показывает, ЧТО не так со словами, но не показывает ни ударения,
/// ни связок, ни того, что правильный вариант звучит совсем не так, как
/// читается глазами. Для языка это половина дела, и до сих пор этой
/// половины в разборе не было.
///
/// Озвучивается ТОЛЬКО изучаемый язык: слушать образец произношения на
/// родном незачем, а перепутать их — значит выдать игроку неверное
/// произношение с видом образца.
class SpeakButton extends StatefulWidget {
  /// Что озвучивать — исправленная фраза целиком.
  final String text;

  /// Двухбуквенный код изучаемого языка. Пусто — кнопки не будет: язык
  /// подставлять «по умолчанию» здесь нельзя, это и есть та самая ошибка,
  /// от которой кнопка должна защищать.
  final String languageCode;

  const SpeakButton({super.key, required this.text, required this.languageCode});

  @override
  State<SpeakButton> createState() => _SpeakButtonState();
}

class _SpeakButtonState extends State<SpeakButton> {
  final _player = AudioPlayer();
  bool _loading = false;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    // Второе нажатие во время проигрывания останавливает: кнопка одна, и
    // она обязана уметь отменить то, что сама запустила.
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    if (_loading) return;

    setState(() => _loading = true);
    try {
      final bytes = await SpeechPlayback.audioFor(widget.languageCode, widget.text);
      if (!mounted) return;
      await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      if (!mounted) return;
      setState(() {
        _loading = false;
        _playing = true;
      });
    } on SpeechUnavailable catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      // Причина отказа приходит с сервера уже человеческим текстом: «нет
      // ключа», «язык не совпадает с парой». Прятать её за общим «не
      // получилось» значит заставить чинить вслепую.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Озвучить не вышло: ${e.reason}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Озвучить не вышло: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.languageCode.isEmpty || widget.text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return InkResponse(
      onTap: _toggle,
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: _loading
            ? const SizedBox(
                height: 14,
                width: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold),
              )
            : Icon(
                _playing ? Icons.stop_rounded : Icons.volume_up_rounded,
                size: 16,
                color: AppColors.gold,
              ),
      ),
    );
  }
}
