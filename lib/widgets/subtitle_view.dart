import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/audio_track.dart';

/// Текст трека: строками, звучащее слово — золотом.
///
/// ЛЕНТА ЕДЕТ САМА. Держать активную строку в поле зрения вручную игрок не
/// может: у него заняты уши, а руки не при делах — он слушает. Прокрутка
/// идёт к строке, а не к слову: подтягивать экран на каждое слово значит
/// трясти текст без остановки.
class SubtitleView extends StatefulWidget {
  final AudioTrack track;

  /// Сквозной номер звучащего слова. -1 — ещё не началось.
  final int activeWord;

  final double fontSize;

  const SubtitleView({
    super.key,
    required this.track,
    required this.activeWord,
    this.fontSize = 16,
  });

  @override
  State<SubtitleView> createState() => _SubtitleViewState();
}

class _SubtitleViewState extends State<SubtitleView> {
  final _controller = ScrollController();
  final _lineKeys = <int, GlobalKey>{};
  int _shownLine = -1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _lineOf(int index) {
    if (index < 0) return -1;
    var seen = 0;
    for (var line = 0; line < widget.track.lines.length; line++) {
      final count = widget.track.lines[line].words.length;
      if (index < seen + count) return line;
      seen += count;
    }
    return widget.track.lines.length - 1;
  }

  void _keepVisible(int line) {
    if (line < 0 || line == _shownLine) return;
    _shownLine = line;
    final context = _lineKeys[line]?.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      // Активная строка встаёт в середину, а не к краю: так видно и то, что
      // уже спето, и то, что сейчас споют.
      alignment: 0.5,
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeLine = _lineOf(widget.activeWord);
    WidgetsBinding.instance.addPostFrameCallback((_) => _keepVisible(activeLine));

    var wordIndex = 0;
    final lines = <Widget>[];
    for (var line = 0; line < widget.track.lines.length; line++) {
      final spans = <InlineSpan>[];
      for (final word in widget.track.lines[line].words) {
        final isActive = wordIndex == widget.activeWord;
        final isPast = wordIndex < widget.activeWord;
        spans.add(TextSpan(
          text: '${word.text} ',
          style: TextStyle(
            fontSize: widget.fontSize,
            height: 1.5,
            fontWeight: isActive ? FontWeight.w800 : FontWeight.w500,
            // Спетое тускнеет, неспетое ждёт обычным цветом, звучащее —
            // золотое. Три состояния вместо двух: без них непонятно, где ты
            // внутри строки, когда подсветка ушла вперёд.
            color: isActive
                ? AppColors.gold
                : isPast
                    ? AppColors.muted
                    : AppColors.cream,
          ),
        ));
        wordIndex++;
      }
      _lineKeys.putIfAbsent(line, () => GlobalKey());
      lines.add(Padding(
        key: _lineKeys[line],
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text.rich(TextSpan(children: spans)),
      ));
    }

    return ListView(
      controller: _controller,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: lines,
    );
  }
}
