import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/theme.dart';
import '../../core/track_clock.dart';
import '../../data/library_track.dart';
import '../../data/practice_session.dart';
import '../../data/streaks.dart';
import '../../data/track_library.dart';
import '../../data/track_subtitles.dart';

/// Экран чтения: два связных текста рядом, поперёк экрана.
///
/// ЧТО ЗДЕСЬ БЫЛО РАНЬШЕ. На экране жила ОДНА строка за раз: отыграла —
/// сменилась следующей. Смысл был в крупном слове, но цена оказалась выше:
/// прочитанное исчезало, а непрочитанного ещё не было, и вернуться взглядом
/// было некуда. Для чтения текста это ровно наоборот тому, что нужно.
///
/// ЧТО СТАЛО. Текст виден весь и целиком, слева оригинал, справа перевод, и
/// его можно листать в обе стороны. Строки идут ПАРАМИ в общем списке — так
/// перевод не может уехать относительно оригинала ни на пиксель, даже когда
/// одна сторона переносится на три строки, а другая на одну.
///
/// ПОЧЕМУ ПОПЕРЁК. Две колонки текста рядом в ширину телефона стоймя не
/// помещаются: на каждую осталось бы по два-три слова, и обе стали бы
/// лестницей из обрывков.
///
/// ПАЛОЧКА ПОСЕРЕДИНЕ — НЕ УКРАШЕНИЕ. Кому-то нужен оригинал с подсказкой
/// сбоку, кому-то перевод с оригиналом для сверки; это разные занятия, и
/// делить экран поровну для обоих неправильно. Двинув её до края, можно
/// убрать любую из колонок совсем.
class PlayerScreen extends StatefulWidget {
  final String trackId;

  const PlayerScreen({super.key, required this.trackId});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

enum _Stage { loading, failed, playing }

/// Какие плашки перемотки открыты. Открытыми они и остаются — закрывает их
/// игрок, ткнув мимо.
enum _SeekMenu { none, back, forward }

class _PlayerScreenState extends State<PlayerScreen> {
  final AudioPlayer _player = AudioPlayer();
  final TrackClock _clock = TrackClock();
  final ItemScrollController _scroll = ItemScrollController();
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

  /// Доля ширины под оригинал. 0 — только перевод, 1 — только оригинал.
  double _split = 0.5;

  /// Скорость воспроизведения. Часы о ней знают (TrackClock.rate) — иначе
  /// подсветка отставала бы тем сильнее, чем дальше играет запись.
  double _speed = 1.0;

  _SeekMenu _menu = _SeekMenu.none;

  /// Список сам идёт за активной строкой. Выключается, как только игрок
  /// листает руками: увести текст у него из-под пальца — худшее, что может
  /// сделать автопрокрутка.
  bool _following = true;
  Timer? _resumeFollow;

  bool _portrait = true;
  bool _started = false;
  bool _pausedByRotation = false;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _clock.addListener(_onTick);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    if (portrait == _portrait) return;
    _portrait = portrait;
    _applyOrientation();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _resumeFollow?.cancel();
    _clock.removeListener(_onTick);
    _clock.dispose();
    _player.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // Загрузка
  // -------------------------------------------------------------------

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

      // ГОТОВИМ, НО НЕ ИГРАЕМ. Пуск — дело _applyOrientation: пока телефон
      // стоймя, играть некому.
      await _player.setSource(
        track.isUploaded ? DeviceFileSource(track.path) : AssetSource(track.assetPath),
      );
      await _applyOrientation();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = '$e';
      });
    }
  }

  // -------------------------------------------------------------------
  // Ход записи
  // -------------------------------------------------------------------

  void _onTick() {
    if (_stage != _Stage.playing) return;
    final position = _clock.positionMs;
    final line = activeIndex(_lineStarts, position);
    final word = line < 0 ? -1 : activeIndex(_wordStarts[line], position);
    if (line == _line && word == _word) return;
    final moved = line != _line;
    setState(() {
      _line = line;
      _word = word;
    });
    if (moved) _followLine(line);
  }

  /// Подводит список к активной строке. Не дальше от края, чем на треть:
  /// читать удобнее, когда впереди видно, что будет дальше.
  void _followLine(int line) {
    if (!_following || line < 0 || !_scroll.isAttached) return;
    _scroll.scrollTo(
      index: line,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      alignment: 0.35,
    );
  }

  /// Игрок листает сам — не мешаем. Через несколько секунд после того, как
  /// он отпустил, список снова догоняет запись.
  void _onUserScroll() {
    _resumeFollow?.cancel();
    if (_following) setState(() => _following = false);
    _resumeFollow = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      setState(() => _following = true);
      _followLine(_line);
    });
  }

  int get _durationMs {
    final subtitles = _subtitles;
    final byTrack = _track?.durationMs ?? 0;
    final bySubtitles = subtitles?.durationMs ?? 0;
    return byTrack > bySubtitles ? byTrack : bySubtitles;
  }

  Future<void> _seekBy(int seconds) async {
    final target = (_clock.positionMs + seconds * 1000).clamp(0, _durationMs);
    await _player.seek(Duration(milliseconds: target));
    _clock.seekTo(target);
    // Перемотка — это намеренный прыжок: возвращаем автопрокрутку, иначе
    // игрок прыгнул, а текст остался там, где был.
    _resumeFollow?.cancel();
    _following = true;
    _onTick();
    _followLine(activeIndex(_lineStarts, target));
    if (mounted) setState(() {});
  }

  Future<void> _setSpeed(double speed) async {
    await _player.setPlaybackRate(speed);
    _clock.rate = speed;
    if (mounted) setState(() => _speed = speed);
  }

  Future<void> _applyOrientation() async {
    if (_applying) return;
    _applying = true;
    try {
      while (mounted && _stage == _Stage.playing) {
        final portrait = _portrait;
        await _applyOnce(portrait);
        if (portrait == _portrait) break;
      }
    } finally {
      _applying = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _applyOnce(bool portrait) async {
    if (portrait) {
      if (!_clock.running) return;
      await _player.pause();
      _clock.pause();
      _pausedByRotation = true;
      await WakelockPlus.disable();
    } else if (!_started) {
      _started = true;
      _pausedByRotation = false;
      await _player.resume();
      _clock.start();
      await WakelockPlus.enable();
    } else if (_pausedByRotation) {
      _pausedByRotation = false;
      await _player.resume();
      _clock.resume();
      await WakelockPlus.enable();
    }
  }

  Future<void> _togglePlay() async {
    if (_clock.running) {
      await _player.pause();
      _clock.pause();
      await WakelockPlus.disable();
    } else {
      // Запись кончилась — начинаем сначала, а не упираемся в конец.
      final fromStart = _clock.completed || _clock.positionMs >= _durationMs;
      if (fromStart) await _player.seek(Duration.zero);
      await _player.resume();
      // start() против resume(): он же заводит счётчик кадров заново, а
      // markCompleted его погасил. Иначе звук пошёл бы, а подсветка стояла.
      fromStart ? _clock.start() : _clock.resume();
      await WakelockPlus.enable();
    }
    _pausedByRotation = false;
    if (mounted) setState(() {});
  }

  void _finish() {
    // Текст НЕ УБИРАЕМ. Запись кончилась — читать её ещё можно, и кнопка
    // играет снова с начала.
    _clock.pause();
    _clock.markCompleted();
    WakelockPlus.disable();
    // ДОСЛУШАННАЯ ЗАПИСЬ — ЭТО ЗАНЯТИЕ. Отмечаем здесь, а не на входе в
    // экран: серия за открытый и тут же закрытый экран — не серия.
    unawaited(countAsPractice(PracticeMode.listening));
    if (mounted) setState(() {});
  }

  void _leave() {
    _player.stop();
    _clock.markCompleted();
    if (!mounted) return;
    context.canPop() ? context.pop() : context.go('/arena');
  }

  // -------------------------------------------------------------------
  // Экран
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    return Scaffold(
      backgroundColor: AppColors.navy1,
      body: SafeArea(child: _body(portrait)),
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
      case _Stage.playing:
        // Плашка уходит САМА при повороте: MediaQuery пересчитывается, и
        // экран перестраивается — нажимать нечего и не нужно.
        return portrait ? const _RotateHint() : _reader();
    }
  }

  Widget _reader() {
    final subtitles = _subtitles!;
    return LayoutBuilder(
      builder: (context, box) {
        const handle = 20.0;
        final usable = (box.maxWidth - handle).clamp(0.0, double.infinity);
        final left = (usable * _split).clamp(0.0, usable);
        final right = usable - left;

        return Stack(
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  const SizedBox(height: 46),
                  Expanded(
                    child: NotificationListener<ScrollStartNotification>(
                      // dragDetails есть только у прокрутки пальцем: наша
                      // собственная прокрутка к строке его не ставит, иначе
                      // список выключал бы автопрокрутку сам себе.
                      onNotification: (n) {
                        if (n.dragDetails != null) _onUserScroll();
                        return false;
                      },
                      child: ScrollablePositionedList.builder(
                        itemScrollController: _scroll,
                        itemCount: subtitles.lines.length,
                        padding: const EdgeInsets.only(bottom: 120),
                        itemBuilder: (context, i) => _ReaderLine(
                          line: subtitles.lines[i],
                          leftWidth: left,
                          rightWidth: right,
                          gap: handle,
                          active: i == _line,
                          activeWord: i == _line ? _word : -1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Палочка. Текст под неё не заходит: ширина колонок считается
            // за вычетом её собственной.
            Positioned(
              left: left,
              top: 46,
              bottom: 0,
              width: handle,
              child: _Handle(
                onDrag: (dx) => setState(() {
                  _split = ((left + dx) / usable).clamp(0.0, 1.0);
                }),
              ),
            ),

            // Ткнул мимо плашек — плашки закрылись. Слой ниже панели, чтобы
            // сами плашки оставались нажимаемыми.
            if (_menu != _SeekMenu.none)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => setState(() => _menu = _SeekMenu.none),
                ),
              ),

            Positioned(top: 0, left: 0, right: 0, child: _topBar()),
          ],
        );
      },
    );
  }

  Widget _topBar() {
    return SizedBox(
      height: 46,
      child: LayoutBuilder(
        builder: (context, box) {
          const button = 38.0;
          const step = 36.0;
          const gap = 6.0;
          const steps = [5, 10, 30, 50];
          final middle = box.maxWidth / 2;
          // Две кнопки стоят ровно по центру, а плашки лежат СЛОЕМ ПОВЕРХ и
          // ширины не занимают. Держи мы их в общем ряду — на узком экране
          // панель не поместилась бы, а кнопки прыгали бы вбок ровно в тот
          // момент, когда по ним целятся.
          final chipsWidth = steps.length * (step + gap);

          return Stack(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: _leave,
                  icon: const Icon(Icons.arrow_back, color: AppColors.muted),
                ),
              ),

              Positioned(
                left: middle - button - gap / 2,
                top: 4,
                child: _RoundButton(
                  icon: Icons.replay,
                  active: _menu == _SeekMenu.back,
                  onTap: () => setState(() => _menu =
                      _menu == _SeekMenu.back ? _SeekMenu.none : _SeekMenu.back),
                ),
              ),
              Positioned(
                left: middle + gap / 2,
                top: 4,
                child: _RoundButton(
                  icon: Icons.replay,
                  mirrored: true,
                  active: _menu == _SeekMenu.forward,
                  onTap: () => setState(() => _menu = _menu == _SeekMenu.forward
                      ? _SeekMenu.none
                      : _SeekMenu.forward),
                ),
              ),

              // Назад — плашки слева от кнопки, вперёд — справа.
              if (_menu == _SeekMenu.back)
                Positioned(
                  left: middle - button - gap / 2 - chipsWidth,
                  top: 6,
                  child: Row(
                    children: [
                      for (final value in steps.reversed)
                        _StepChip(step: value, onTap: () => _seekBy(-value)),
                    ],
                  ),
                ),
              if (_menu == _SeekMenu.forward)
                Positioned(
                  left: middle + gap / 2 + button,
                  top: 6,
                  child: Row(
                    children: [
                      for (final value in steps)
                        _StepChip(step: value, onTap: () => _seekBy(value)),
                    ],
                  ),
                ),

              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SpeedButton(speed: _speed, onPick: _setSpeed),
                    IconButton(
                      onPressed: _togglePlay,
                      icon: Icon(_clock.running ? Icons.pause : Icons.play_arrow,
                          color: AppColors.gold),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Пара строк: оригинал слева, перевод справа, ровно друг напротив друга.
class _ReaderLine extends StatelessWidget {
  final SubtitleLine line;
  final double leftWidth;
  final double rightWidth;
  final double gap;
  final bool active;
  final int activeWord;

  const _ReaderLine({
    required this.line,
    required this.leftWidth,
    required this.rightWidth,
    required this.gap,
    required this.active,
    required this.activeWord,
  });

  /// Какое слово перевода соответствует активному слову оригинала.
  ///
  /// ЭТО СООТВЕТСТВИЕ ПРИБЛИЖЁННОЕ, и честнее сказать это прямо. Переводчик
  /// переводит СТРОКУ, а не слова по отдельности: в переводе может быть
  /// другое число слов и другой их порядок. Поэтому подсвечивается слово на
  /// том же месте по счёту — а вся строка перевода при этом светлеет
  /// целиком, чтобы взгляд попадал туда, даже когда слово промахнулось.
  int get _mirrorWord {
    if (activeWord < 0 || line.words.isEmpty) return -1;
    final tokens = line.translationText.split(RegExp(r'\s+'))
      ..removeWhere((t) => t.isEmpty);
    if (tokens.isEmpty) return -1;
    final at = ((activeWord + 0.5) * tokens.length / line.words.length).floor();
    return at.clamp(0, tokens.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: leftWidth,
            child: leftWidth < 8
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: 18, right: 6),
                    child: _Words(
                      words: [for (final w in line.words) w.text],
                      active: activeWord,
                      dim: !active,
                      size: 19,
                    ),
                  ),
          ),
          SizedBox(width: gap),
          SizedBox(
            width: rightWidth,
            child: rightWidth < 8
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: 6, right: 18),
                    child: _Words(
                      words: line.translationText
                          .split(RegExp(r'\s+'))
                          .where((t) => t.isNotEmpty)
                          .toList(),
                      active: _mirrorWord,
                      dim: !active,
                      size: 17,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Слова одной стороны с подсветкой активного.
class _Words extends StatelessWidget {
  final List<String> words;
  final int active;
  final bool dim;
  final double size;

  const _Words({
    required this.words,
    required this.active,
    required this.dim,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    if (words.isEmpty) return const SizedBox.shrink();
    final base = dim ? AppColors.muted : AppColors.cream;
    return RichText(
      text: TextSpan(
        style: AppFonts.ui(fontSize: size, color: base).copyWith(height: 1.45),
        children: [
          for (var i = 0; i < words.length; i++)
            TextSpan(
              text: i == words.length - 1 ? words[i] : '${words[i]} ',
              style: i == active
                  ? TextStyle(
                      color: AppColors.gold,
                      fontWeight: FontWeight.w800,
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}

/// Палочка между колонками. Тянется пальцем, текст идёт за ней.
class _Handle extends StatelessWidget {
  final void Function(double dx) onDrag;

  const _Handle({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: Center(
          child: Container(
            width: 3,
            decoration: BoxDecoration(
              color: AppColors.lineStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

/// Круглая стрелка перемотки.
class _RoundButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final bool mirrored;
  final VoidCallback onTap;

  const _RoundButton({
    required this.icon,
    required this.active,
    required this.onTap,
    this.mirrored = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 26,
      child: Container(
        height: 38,
        width: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? AppColors.goldSoft : Colors.transparent,
          border: Border.all(color: active ? AppColors.gold : AppColors.line),
        ),
        child: Transform.scale(
          scaleX: mirrored ? -1 : 1,
          child: Icon(icon, size: 20, color: active ? AppColors.gold : AppColors.muted),
        ),
      ),
    );
  }
}

/// Квадратная плашка с шагом перемотки. Нажатие её НЕ закрывает: игрок сам
/// решает, сколько раз подряд перемотать и когда закончить.
class _StepChip extends StatelessWidget {
  final int step;
  final VoidCallback onTap;

  const _StepChip({required this.step, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 34,
          width: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.navy2,
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('$step',
              style: AppFonts.mono(
                  fontSize: 12, weight: FontWeight.w700, color: AppColors.cream)),
        ),
      ),
    );
  }
}

/// Скорость записи. Нажатие перебирает значения по кругу — одно касание, и
/// текущее всегда написано на кнопке.
class _SpeedButton extends StatelessWidget {
  static const List<double> steps = [0.75, 1.0, 1.25, 1.5, 0.5];

  final double speed;
  final ValueChanged<double> onPick;

  const _SpeedButton({required this.speed, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        final at = steps.indexOf(speed);
        onPick(steps[(at < 0 ? 1 : at + 1) % steps.length]);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('${speed.toStringAsFixed(2)}×',
            style: AppFonts.mono(
                fontSize: 11, weight: FontWeight.w700, color: AppColors.cream)),
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
              'Два текста рядом — оригинал и перевод — в ширину экрана '
              'стоймя не помещаются.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
