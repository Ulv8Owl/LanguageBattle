import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

import '../core/theme.dart';
import 'chrolingo_widgets.dart';

/// Готовое, но ещё не отправленное голосовое.
class VoiceTake {
  final String filePath;

  /// Транскрипт со встроенного ASR ОС (раздел 9.1 — осознанно временное
  /// решение). Может быть пустым, если движок ничего не разобрал.
  final String transcript;
  final double confidence;
  final double durationSeconds;

  const VoiceTake({
    required this.filePath,
    required this.transcript,
    required this.confidence,
    required this.durationSeconds,
  });
}

/// Локали встроенного распознавания речи по коду языка.
const speechLocaleByLanguage = {
  'en': 'en_US',
  'es': 'es_ES',
  'ru': 'ru_RU',
};

enum _MicState { idle, recording, ready }

/// Кнопка микрофона с тремя состояниями (раздел 5.2):
/// 1. ожидание — белый кружок с микрофоном;
/// 2. идёт запись — жёлтый кружок с пульсирующим свечением;
/// 3. запись готова — жёлтый кружок с иконкой «отправить», сверху превью
///    записанного голосового с плеером.
///
/// Никаких текстовых подсказок: состояние передаётся только видом кнопки.
/// Сброс подготовленной записи делает родительский экран по тапу мимо
/// кнопки — через [VoiceRecorderDockState.cancelPending].
class VoiceRecorderDock extends StatefulWidget {
  final bool enabled;

  /// Язык, на котором ожидается речь — определяет локаль ASR.
  final String languageCode;

  /// Отправка. Пока future не завершился, кнопка показывает прогресс.
  final Future<void> Function(VoiceTake take) onSend;

  const VoiceRecorderDock({
    super.key,
    required this.enabled,
    required this.languageCode,
    required this.onSend,
  });

  @override
  State<VoiceRecorderDock> createState() => VoiceRecorderDockState();
}

class VoiceRecorderDockState extends State<VoiceRecorderDock> with SingleTickerProviderStateMixin {
  final _recorder = AudioRecorder();
  final _speech = SpeechToText();

  bool _speechAvailable = false;
  _MicState _micState = _MicState.idle;
  String? _pendingFilePath;
  String _liveTranscript = '';
  double _liveConfidence = 1.0;
  Stopwatch? _stopwatch;
  bool _uploading = false;

  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  /// true, если есть записанное, но ещё не отправленное голосовое.
  bool get hasPendingTake => _micState == _MicState.ready && !_uploading;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    try {
      _speechAvailable = await _speech.initialize(
        onError: (e) => debugPrint('speech_to_text error: $e'),
      );
    } catch (e) {
      debugPrint('speech_to_text init failed: $e');
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _recorder.dispose();
    _speech.cancel();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (_micState != _MicState.idle || _uploading) return;
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нет доступа к микрофону')),
        );
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${const Uuid().v4()}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);

    _liveTranscript = '';
    _liveConfidence = 1.0;
    if (_speechAvailable) {
      // Распознавание идёт параллельно с записью файла — транскрипт готов
      // сразу, без отдельного шага облачного ASR (раздел 9.1). На части
      // устройств одновременный доступ к микрофону из record и
      // speech_to_text может не сработать: тогда транскрипта просто не
      // будет, и оценка мягко деградирует, а не падает.
      unawaited(_speech.listen(
        onResult: (result) {
          _liveTranscript = result.recognizedWords;
          if (result.confidence > 0) _liveConfidence = result.confidence;
        },
        listenOptions: SpeechListenOptions(
          localeId: speechLocaleByLanguage[widget.languageCode] ?? 'en_US',
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
      ));
    }

    if (!mounted) return;
    setState(() {
      _micState = _MicState.recording;
      _pendingFilePath = path;
      _stopwatch = Stopwatch()..start();
    });
  }

  Future<void> _stopRecording() async {
    if (_micState != _MicState.recording) return;
    final path = await _recorder.stop();
    if (_speechAvailable) await _speech.stop();
    _stopwatch?.stop();
    if (!mounted) return;
    setState(() {
      _micState = _MicState.ready;
      if (path != null) _pendingFilePath = path;
    });
  }

  /// Сброс подготовленной записи — можно записать заново.
  void cancelPending() {
    final path = _pendingFilePath;
    if (path != null) {
      File(path).delete().catchError((_) => File(path));
    }
    if (!mounted) return;
    setState(() {
      _micState = _MicState.idle;
      _pendingFilePath = null;
      _stopwatch = null;
    });
  }

  Future<void> _send() async {
    final path = _pendingFilePath;
    if (path == null || _uploading) return;
    setState(() => _uploading = true);
    try {
      await widget.onSend(VoiceTake(
        filePath: path,
        transcript: _liveTranscript.trim(),
        confidence: _liveConfidence,
        durationSeconds: (_stopwatch?.elapsedMilliseconds ?? 0) / 1000.0,
      ));
      if (!mounted) return;
      setState(() {
        _micState = _MicState.idle;
        _pendingFilePath = null;
        _stopwatch = null;
      });
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.navy2,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_micState == _MicState.ready) ...[
            _PendingPreview(path: _pendingFilePath),
            const SizedBox(height: 10),
          ],
          _buildButton(),
        ],
      ),
    );
  }

  Widget _buildButton() {
    final disabled = !widget.enabled;
    Widget circle;
    switch (_micState) {
      case _MicState.idle:
        circle = _MicCircle(
          color: disabled ? Colors.white24 : Colors.white,
          icon: Icons.mic,
        );
        break;
      case _MicState.recording:
        circle = AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) => Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.gold.withValues(alpha: 0.6),
                  blurRadius: 10 + _pulseController.value * 14,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: child,
          ),
          child: const _MicCircle(color: AppColors.gold, icon: Icons.mic),
        );
        break;
      case _MicState.ready:
        circle = _uploading
            ? const _MicCircle(
                color: AppColors.gold,
                icon: null,
                child: SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                ),
              )
            : const _MicCircle(color: AppColors.gold, icon: Icons.send);
        break;
    }

    return GestureDetector(
      onLongPressStart: disabled ? null : (_) => _startRecording(),
      onLongPressEnd: disabled ? null : (_) => _stopRecording(),
      onTap: (_micState == _MicState.ready && !_uploading) ? _send : null,
      child: circle,
    );
  }
}

class _MicCircle extends StatelessWidget {
  final Color color;
  final IconData? icon;
  final Widget? child;

  const _MicCircle({required this.color, required this.icon, this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      width: 64,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Center(child: child ?? Icon(icon, color: Colors.black, size: 28)),
    );
  }
}

/// Превью записанного, но ещё не отправленного голосового.
class _PendingPreview extends StatefulWidget {
  final String? path;

  const _PendingPreview({required this.path});

  @override
  State<_PendingPreview> createState() => _PendingPreviewState();
}

class _PendingPreviewState extends State<_PendingPreview> {
  final _player = AudioPlayer();
  bool _playing = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final path = widget.path;
    if (path == null) return;
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    await _player.play(DeviceFileSource(path));
    if (!mounted) return;
    setState(() => _playing = true);
    _player.onPlayerComplete.first.then((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.navy3,
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _toggle,
            child: Icon(_playing ? Icons.stop : Icons.play_arrow, color: AppColors.gold, size: 22),
          ),
          const SizedBox(width: 10),
          const ChWaveform(width: 120, color: AppColors.gold),
        ],
      ),
    );
  }
}
