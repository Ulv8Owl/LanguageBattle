import 'dart:async';

import 'package:flutter/foundation.dart';

/// Часы записи: где мы сейчас внутри неё, с точностью кадра.
///
/// ЗАЧЕМ СВОИ ЧАСЫ, КОГДА ПЛЕЕР И ТАК СООБЩАЕТ ПОЗИЦИЮ. Сообщает он её
/// примерно пять раз в секунду. Для полоски перемотки этого достаточно, для
/// подсветки слова — нет: слово звучит полсекунды, и на таком шаге
/// подсветка прыгала бы через одно, а короткие слова пропускала бы совсем.
///
/// ПОЭТОМУ ВРЕМЯ СЧИТАЕТСЯ ЛОКАЛЬНО, а редкие сообщения плеера служат
/// поправкой: между ними позиция растёт сама по системным часам, а как
/// только плеер скажет своё — расхождение проверяется, и если оно заметное
/// (перемотка, залипание буфера, пауза от системы), часы подводятся под
/// плеер. Локальные часы врут медленно, плеер отвечает редко; вместе они
/// дают и плавность, и правду.
class TrackClock extends ChangeNotifier {
  /// Расхождение, начиная с которого верим плееру, а не себе. Меньше этого
  /// — обычное дрожание доставки события, и подводить часы под него значит
  /// дёргать подсветку на ровном месте.
  static const int _resyncThresholdMs = 140;

  Timer? _ticker;
  final Stopwatch _since = Stopwatch();
  int _anchorMs = 0;
  bool _completed = false;

  int get positionMs => _anchorMs + _since.elapsedMilliseconds;

  bool get completed => _completed;

  bool get running => _since.isRunning;

  void start() {
    _completed = false;
    _anchorMs = 0;
    _since
      ..reset()
      ..start();
    _ticker?.cancel();
    // 16 мс — кадр при 60 Гц. Чаще считать незачем: чаще экран всё равно не
    // перерисуется.
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_completed) return;
      notifyListeners();
    });
  }

  void pause() {
    _anchorMs = positionMs;
    _since
      ..stop()
      ..reset();
    notifyListeners();
  }

  void resume() {
    _since
      ..reset()
      ..start();
    notifyListeners();
  }

  void seekTo(int ms) {
    _anchorMs = ms < 0 ? 0 : ms;
    _since.reset();
    _completed = false;
    notifyListeners();
  }

  /// Позиция, которую сообщил плеер. Зовётся редко — это поправка, а не
  /// источник времени.
  void syncTo(Duration reported) {
    final drift = reported.inMilliseconds - positionMs;
    if (drift.abs() < _resyncThresholdMs) return;
    _anchorMs = reported.inMilliseconds;
    if (_since.isRunning) {
      _since
        ..reset()
        ..start();
    } else {
      _since.reset();
    }
  }

  void markCompleted() {
    if (_completed) return;
    _completed = true;
    _since.stop();
    _ticker?.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

/// Какой элемент звучит в момент [positionMs].
///
/// ВОЗВРАЩАЕТ ПОСЛЕДНИЙ НАЧАВШИЙСЯ, а не только тот, внутри которого мы
/// буквально находимся. Между словами есть паузы, и в паузе «активного нет»
/// — но гасить подсветку на каждый вдох значит мигать ею всю дорогу.
///
/// Список обязан быть упорядочен по началу — так его и приводит в порядок
/// TrackSubtitles.normalized().
int activeIndex(List<int> startsMs, int positionMs) {
  if (startsMs.isEmpty || positionMs < startsMs.first) return -1;
  var low = 0;
  var high = startsMs.length - 1;
  while (low < high) {
    final mid = (low + high + 1) ~/ 2;
    if (startsMs[mid] <= positionMs) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low;
}
