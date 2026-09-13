import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/track_clock.dart';
import '../../data/audio_track.dart';
import '../../widgets/subtitle_view.dart';

/// Режим «Аудирование» — слушать и видеть, что именно звучит.
///
/// ЭКРАН ПОПОЛАМ. Сверху звучащее слово золотом и его перевод белым под ним,
/// оба крупные. Снизу весь текст, в котором это же слово подсвечено.
///
/// ПОЧЕМУ ЗДЕСЬ НЕТ НИ КНОПОК ВЫБОРА, НИ ОЧКОВ. Прошлая пара режимов
/// заставляла игрока успевать: выбрать перевод из трёх, продержать круг
/// ровно столько, сколько длится слово. Это превращало слушание в реакцию —
/// человек следил за кнопками, а не за речью. Здесь не нужно успевать
/// ничего: связь «звук — слово — перевод» показывается сама, а работа
/// игрока в том, чтобы слушать.
///
/// ДВА ЭТАЖА ГОВОРЯТ ОДНО И ТО ЖЕ РАЗНЫМИ СПОСОБАМИ, и это не дублирование.
/// Сверху — что значит то, что звучит прямо сейчас; снизу — где мы внутри
/// фразы. Порознь ни то ни другое не отвечает на оба вопроса сразу.
class ListeningScreen extends StatefulWidget {
  final String trackId;

  const ListeningScreen({super.key, required this.trackId});

  @override
  State<ListeningScreen> createState() => _ListeningScreenState();
}

enum _Stage { loading, failed, playing, done }

class _ListeningScreenState extends State<ListeningScreen> {
  final AudioPlayer _player = AudioPlayer();
  final TrackClock _clock = TrackClock();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  _Stage _stage = _Stage.loading;
  String? _error;

  AudioTrack? _track;
  List<TimedWord> _words = const [];
  List<int> _starts = const [];

  int _activeWord = -1;
  double _rate = 1.0;

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
      final track = await TrackCatalog.load(widget.trackId);
      if (track.lines.isEmpty) throw Exception('в разметке трека нет слов');

      if (!mounted) return;
      final words = track.words;
      final starts = [for (final word in words) word.startMs];
      _subscriptions.add(_player.onPositionChanged.listen(_clock.syncTo));
      _subscriptions.add(_player.onPlayerComplete.listen((_) => _finish()));

      setState(() {
        _track = track;
        _words = words;
        _starts = starts;
        _stage = _Stage.playing;
      });
      await _player.play(AssetSource(track.audioAsset));
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
    final index = activeWordIndex(_starts, _clock.positionMs);
    if (index == _activeWord) return;
    setState(() => _activeWord = index);
  }

  TimedWord? get _current =>
      _activeWord >= 0 && _activeWord < _words.length ? _words[_activeWord] : null;

  Future<void> _setRate(double rate) async {
    if (rate == _rate) return;
    setState(() => _rate = rate);
    // ЧАСАМ СКОРОСТЬ НУЖНА ТАК ЖЕ, КАК ПЛЕЕРУ: они считают по системному
    // времени, и без множителя подсветка ушла бы вперёд ровно во столько
    // раз, во сколько замедлен звук.
    _clock.setRate(rate);
    await _player.setPlaybackRate(rate);
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
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        title: Text(_track?.title ?? 'Аудирование',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_stage == _Stage.playing)
            IconButton(
              onPressed: _togglePlay,
              icon: Icon(_clock.running ? Icons.pause : Icons.play_arrow,
                  color: AppColors.gold),
            ),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.loading:
        return const Center(child: CircularProgressIndicator());
      case _Stage.failed:
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.hearing_disabled, size: 48, color: AppColors.muted),
              const SizedBox(height: 14),
              Text('Не удалось начать: ${_error ?? 'неизвестно'}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4)),
              const SizedBox(height: 20),
              ElevatedButton(onPressed: _load, child: const Text('Ещё раз')),
            ],
          ),
        );
      case _Stage.done:
        return _results();
      case _Stage.playing:
        return _game();
    }
  }

  Widget _game() {
    final track = _track!;
    final word = _current;

    return Column(
      children: [
        // ВЕРХНЯЯ ПОЛОВИНА: слово и перевод одного размера.
        //
        // Перевод НЕ мельче слова намеренно. Мельче он читался бы как
        // сноска, а здесь это равноправная половина связки: игрок смотрит
        // на них как на одно целое, а не на «главное и пояснение».
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      word?.text ?? '…',
                      textAlign: TextAlign.center,
                      style: AppFonts.ui(
                          fontSize: 40, weight: FontWeight.w800, color: AppColors.gold),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      word?.translation ?? '',
                      textAlign: TextAlign.center,
                      style: AppFonts.ui(
                          fontSize: 40, weight: FontWeight.w800, color: AppColors.cream),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        _speedRow(),
        const Divider(height: 1, color: AppColors.line),
        // НИЖНЯЯ ПОЛОВИНА: тот же текст целиком, с тем же подсвеченным словом.
        Expanded(child: SubtitleView(track: track, activeWord: _activeWord)),
      ],
    );
  }

  /// Скорости, которые действительно нужны на слух.
  ///
  /// БЕЗ 0.25 и БЕЗ 2. На четверти речь распадается на отдельные звуки и
  /// разбирать становится нечего; вдвое быстрее не нужно тому, кто пришёл
  /// учить язык.
  static const List<double> _rates = [0.5, 0.75, 1.0, 1.25, 1.5];

  Widget _speedRow() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.speed, size: 13, color: AppColors.muted),
            const SizedBox(width: 8),
            for (final rate in _rates) ...[
              _SpeedChip(
                rate: rate,
                selected: rate == _rate,
                onTap: () => _setRate(rate),
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      );

  Widget _results() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_outline, size: 52, color: AppColors.ok),
            const SizedBox(height: 14),
            Text('Трек закончился',
                style: AppFonts.ui(
                    fontSize: 18, weight: FontWeight.w800, color: AppColors.cream)),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(onPressed: _leave, child: const Text('Завершить')),
            ),
          ],
        ),
      );
}

/// Кнопка скорости. Маленькая и в один ряд: это настройка, а не действие
/// режима, и места у текста она занимать не должна.
class _SpeedChip extends StatelessWidget {
  final double rate;
  final bool selected;
  final VoidCallback onTap;

  const _SpeedChip({required this.rate, required this.selected, required this.onTap});

  /// «1×», «0.5×» — без лишнего нуля в конце.
  String get _label {
    final text = rate.toStringAsFixed(2);
    return '${text.replaceFirst(RegExp(r'\.?0+$'), '')}×';
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? AppColors.goldSoft : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? AppColors.gold : AppColors.line),
        ),
        child: Text(
          _label,
          style: AppFonts.mono(
            fontSize: 10,
            weight: FontWeight.w700,
            color: selected ? AppColors.gold : AppColors.muted,
          ),
        ),
      ),
    );
  }
}
