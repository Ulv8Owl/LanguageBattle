import 'dart:async';

import 'package:flutter/foundation.dart';

/// Часы трека: где мы сейчас внутри записи, с точностью кадра.
///
/// ЗАЧЕМ СВОИ ЧАСЫ, КОГДА ПЛЕЕР И ТАК СООБЩАЕТ ПОЗИЦИЮ. Сообщает он её
/// примерно пять раз в секунду. Для полоски перемотки этого достаточно, для
/// подсветки слова — нет: слово звучит полсекунды, и на таком шаге подсветка
/// прыгала бы через одно, а короткие слова пропускала бы совсем.
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

  /// Скорость воспроизведения. ЧАСЫ ОБЯЗАНЫ ЕЁ ЗНАТЬ: они считают по
  /// системному времени, а на 0.5× запись проходит вдвое меньше за ту же
  /// секунду. Без множителя подсветка убегала бы от звука тем сильнее, чем
  /// дольше играет трек.
  double _rate = 1.0;

  /// Позиция в ВРЕМЕНИ ЗАПИСИ, а не в прошедшем времени: на половинной
  /// скорости за две секунды по часам проходит одна секунда записи.
  int get positionMs => _anchorMs + (_since.elapsedMilliseconds * _rate).round();

  double get rate => _rate;

  bool get completed => _completed;

  bool get running => _since.isRunning;

  /// Сменить скорость.
  ///
  /// СНАЧАЛА ФИКСИРУЕМ ПРОЙДЕННОЕ, потом меняем множитель: иначе новая
  /// скорость задним числом применилась бы ко всему, что уже отыграно, и
  /// позиция прыгнула бы на середину трека.
  void setRate(double rate) {
    if (rate <= 0 || rate == _rate) return;
    _anchorMs = positionMs;
    if (_since.isRunning) {
      _since
        ..reset()
        ..start();
    } else {
      _since.reset();
    }
    _rate = rate;
    notifyListeners();
  }

  void start() {
    _completed = false;
    _anchorMs = 0;
    _since
      ..reset()
      ..start();
    _ticker?.cancel();
    // 16 мс — кадр при 60 Гц. Чаще считать незачем: чаще экран всё равно
    // не перерисуется.
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

/// Какое слово звучит в момент [positionMs].
///
/// ВОЗВРАЩАЕТ ПОСЛЕДНЕЕ НАЧАВШЕЕСЯ, а не только то, внутри которого мы
/// буквально находимся. Между словами есть паузы, и в паузе «активного
/// слова нет» — но гасить подсветку на каждый вдох значит мигать ею всю
/// дорогу. Слово остаётся подсвеченным, пока не начнётся следующее.
///
/// Список обязан быть упорядочен по началу — так его и пишет разметка.
int activeWordIndex(List<int> startsMs, int positionMs) {
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
