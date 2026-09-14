import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/track_clock.dart';
import '../../data/library_track.dart';
import '../../data/track_library.dart';
import '../../data/track_subtitles.dart';

/// Экран прослушивания: две строки во весь экран, поперёк.
///
/// ПОЧЕМУ ПОПЕРЁК. Строка речи длиннее, чем помещается в ширину телефона
/// стоймя, а резать её переносами нельзя: под каждым словом стоит его
/// перевод, и перенос разорвал бы пару. В альбомной ориентации строка
/// умещается целиком — потому экран её и просит.
///
/// ПРОСИТ, А НЕ ЗАСТАВЛЯЕТ. Поворот экрана — настройка телефона, и
/// выкручивать её за игрока мы не вправе: у кого-то он заблокирован
/// намеренно. Плашка уходит сама, как только телефон повёрнут, — нажимать
/// на неё не нужно и нечем.
///
/// НА ЭКРАНЕ ТОЛЬКО ОДНА СТРОКА ЗА РАЗ. Показать сразу всё — значит
/// показать мелко; здесь весь смысл в том, что слово крупное и видно, какое
/// звучит. Строка отыграла — её сменяет следующая.
class PlayerScreen extends StatefulWidget {
  final String trackId;

  const PlayerScreen({super.key, required this.trackId});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

enum _Stage { loading, failed, playing, done }

class _PlayerScreenState extends State<PlayerScreen> {
  final AudioPlayer _player = AudioPlayer();
  final TrackClock _clock = TrackClock();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  _Stage _stage = _Stage.loading;
  String? _error;

  LibraryTrack? _track;
  TrackSubtitles? _subtitles;

  /// Начала строк и начала слов — по ним ищется активная строка и активное
  /// слово. Считаются один раз: двоичный поиск по ним идёт каждый кадр.
  List<int> _lineStarts = const [];
  List<List<int>> _wordStarts = const [];

  int _line = -1;
  int _word = -1;

  @override
  void initState() {
    super.initState();
    _clock.addListener(_onTick);
    _load();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _clock.removeListener(_onTick);
    _clock.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _stage = _Stage.loading;
      _error = null;
    });
    try {
      final track = await TrackLibrary.byId(widget.trackId);
      if (track == null) throw Exception('записи нет в фонотеке');
      final subtitles = await SubtitleStore.load(track.id);
      if (subtitles == null) throw Exception('запись ещё не разобрана');

      if (!mounted) return;
      _subscriptions.add(_player.onPositionChanged.listen(_clock.syncTo));
      _subscriptions.add(_player.onPlayerComplete.listen((_) => _finish()));

      setState(() {
        _track = track;
        _subtitles = subtitles;
        _lineStarts = [for (final line in subtitles.lines) line.startMs];
        _wordStarts = [
          for (final line in subtitles.lines)
            [for (final word in line.words) word.startMs],
        ];
        _stage = _Stage.playing;
      });

      await _player.play(
        track.isUploaded ? DeviceFileSource(track.path) : AssetSource(track.path),
      );
      _clock.start();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = '$e';
      });
    }
  }

  void _onTick() {
    if (_stage != _Stage.playing) return;
    final position = _clock.positionMs;
    final line = activeIndex(_lineStarts, position);
    final word = line < 0 ? -1 : activeIndex(_wordStarts[line], position);
    if (line == _line && word == _word) return;
    setState(() {
      _line = line;
      _word = word;
    });
  }

  Future<void> _togglePlay() async {
    if (_clock.running) {
      await _player.pause();
      _clock.pause();
    } else {
      await _player.resume();
      _clock.resume();
    }
    if (mounted) setState(() {});
  }

  void _finish() {
    if (_stage == _Stage.done) return;
    _clock.markCompleted();
    setState(() => _stage = _Stage.done);
  }

  void _leave() {
    _player.stop();
    _clock.markCompleted();
    if (!mounted) return;
    context.canPop() ? context.pop() : context.go('/arena');
  }

  @override
  Widget build(BuildContext context) {
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    return Scaffold(
      backgroundColor: AppColors.navy1,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _body(portrait)),
            // Выход и пауза — поверх текста и мелкие: экран занят строками,
            // и всё остальное на нём гость.
            Positioned(
              left: 4,
              top: 4,
              child: IconButton(
                onPressed: _leave,
                icon: const Icon(Icons.arrow_back, color: AppColors.muted),
              ),
            ),
            if (_stage == _Stage.playing && !portrait)
              Positioned(
                right: 4,
                top: 4,
                child: IconButton(
                  onPressed: _togglePlay,
                  icon: Icon(_clock.running ? Icons.pause : Icons.play_arrow,
                      color: AppColors.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(bool portrait) {
    switch (_stage) {
      case _Stage.loading:
        return const Center(child: CircularProgressIndicator());
      case _Stage.failed:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Text('Не удалось начать: ${_error ?? ''}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5)),
          ),
        );
      case _Stage.done:
        return Center(
          child: Text('Запись закончилась',
              style: AppFonts.ui(fontSize: 18, weight: FontWeight.w800, color: AppColors.muted)),
        );
      case _Stage.playing:
        // Плашка уходит САМА при повороте: MediaQuery пересчитывается, и
        // экран перестраивается — нажимать нечего и не нужно.
        return portrait ? const _RotateHint() : _lines();
    }
  }

  Widget _lines() {
    final subtitles = _subtitles!;
    if (_line < 0 || _line >= subtitles.lines.length) {
      return Center(
        child: Text(_track?.title ?? '',
            style: AppFonts.ui(fontSize: 20, weight: FontWeight.w700, color: AppColors.muted)),
      );
    }

    final line = subtitles.lines[_line];
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        child: FittedBox(
          // ВСЯ СТРОКА ЦЕЛИКОМ И БЕЗ ПЕРЕНОСОВ. Перенос разорвал бы пару
          // «слово — перевод», а она здесь главное; лучше уменьшить кегль.
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < line.words.length; i++)
                _WordPair(word: line.words[i], active: i == _word),
            ],
          ),
        ),
      ),
    );
  }
}

/// Слово и его перевод одной колонкой.
///
/// ИМЕННО КОЛОНКОЙ, А НЕ ДВУМЯ ОТДЕЛЬНЫМИ СТРОКАМИ ТЕКСТА. Перевод обязан
/// стоять ровно под своим словом; выкладывая строки порознь, пришлось бы
/// вымерять ширины руками и всё равно разъехаться на первом же длинном
/// слове. Колонка центрирует пару сама и не может её рассогласовать.
class _WordPair extends StatelessWidget {
  final SubtitleWord word;
  final bool active;

  const _WordPair({required this.word, required this.active});

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.gold : AppColors.cream;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            word.text,
            style: AppFonts.ui(
              fontSize: 44,
              weight: active ? FontWeight.w800 : FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            word.translation,
            style: AppFonts.ui(
              fontSize: 28,
              weight: active ? FontWeight.w700 : FontWeight.w500,
              // Перевод тускнее оригинала: слушают запись, а перевод —
              // подсказка к ней, и спорить за внимание он не должен.
              color: active ? AppColors.gold : AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Просьба повернуть телефон. Без кнопок — закрывать её нечем и незачем.
class _RotateHint extends StatelessWidget {
  const _RotateHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.screen_rotation, size: 44, color: AppColors.gold),
            const SizedBox(height: 18),
            Text('Поверни телефон',
                style: AppFonts.ui(fontSize: 20, weight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text(
              'Строка с переводом под каждым словом не помещается в ширину '
              'экрана стоймя.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
