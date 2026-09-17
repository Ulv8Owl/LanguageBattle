/// Мост к нативной части: уведомление со своей разметкой, будильники и
/// виджет (android/app/src/main/kotlin/com/chrolingo/app).
///
/// ═══ ПОЧЕМУ НЕ ПЛАГИН ═══
///
/// flutter_local_notifications умеет только системные шаблоны: заголовок,
/// текст, картинка справа. Ни цветной плашки, ни крупного тикающего
/// счётчика в них нет — для этого нужна своя RemoteViews-разметка, а её
/// плагин не пробрасывает. Пока вечерние напоминания ставил он, превью
/// показывало ОДНО, а вечером приходило ДРУГОЕ.
///
/// ═══ КТО ЧТО РЕШАЕТ ═══
///
/// ЧТО показать и КОГДА — решает Dart: там правила выбора напоминания и
/// там они проверяются тестами. КАК показать — знает Kotlin, потому что
/// вечером Dart уже не запущен: уведомление рисует BroadcastReceiver,
/// разбуженный будильником, когда приложения нет ни в каком виде.
///
/// ═══ ЧЕГО НЕЛЬЗЯ ВООБЩЕ ═══
///
/// Убрать из шапки имя приложения, пока `targetSdk >= 31`. Дословно:
/// «For apps targeting Android 12, notifications with custom content
/// views will no longer use the full notification area; instead, the
/// system applies a standard template». Убирается только штамп времени.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Расцветка плашки. Имена совпадают с картой SKINS в
/// ChrolingoNotification.kt — по ним же ищутся и фоны в res/drawable.
enum NotificationSkin {
  /// Обычное напоминание: золотая плашка, тёмный текст.
  gold,

  /// Срочное: «серия сгорит сегодня».
  ember,
}

/// Одно уведомление целиком — и для показа сейчас, и для будильника.
///
/// ОДИН И ТОТ ЖЕ ВИД НА ОБА СЛУЧАЯ, И ЭТО ГЛАВНОЕ ЕГО СВОЙСТВО. Превью,
/// собранное отдельно от настоящего, перестаёт быть проверкой в тот же
/// день, когда одно из двух правят.
class NotificationSpec {
  final int id;
  final String channelId;
  final String channelName;
  final String title;
  final String body;

  /// Имя файла в `res/raw` без расширения. Звук канала.
  final String? sound;

  /// Имя ресурса настроения в `res/drawable` (`mascot_worried`).
  ///
  /// ИМЕННО РЕСУРС, А НЕ ФАЙЛ И НЕ АССЕТ. Уведомление рисуется, когда
  /// приложения нет: ассеты Flutter читать нечем, а картинку целиком
  /// система отказывается принимать, если та велика. Ресурс уезжает
  /// одним числом, и рисунок берётся из APK — даже если приложение ни
  /// разу не запускали.
  final String? mascot;

  final NotificationSkin skin;

  /// До какого момента идёт обратный отсчёт. null — таймера нет.
  final DateTime? countdownUntil;

  /// Когда показать. null — немедленно.
  final DateTime? at;

  /// Повторять раз в неделю в тот же час.
  final bool repeatWeekly;

  const NotificationSpec({
    required this.id,
    required this.channelId,
    required this.channelName,
    required this.title,
    required this.body,
    this.sound,
    this.mascot,
    this.skin = NotificationSkin.gold,
    this.countdownUntil,
    this.at,
    this.repeatWeekly = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'channelId': channelId,
        'channelName': channelName,
        'title': title,
        'body': body,
        'sound': sound,
        'mascot': mascot,
        'skin': skin.name,
        'countdownUntil': countdownUntil?.millisecondsSinceEpoch,
        // Момент в обычном времени телефона. Никакой базы часовых
        // поясов для этого не нужно: DateTime(год, месяц, день, час)
        // уже посчитан по правилам зоны самого устройства — вместе с
        // переводом стрелок, если он случится до этого дня.
        'at': at?.millisecondsSinceEpoch,
        'repeatWeekly': repeatWeekly,
      };
}

/// Один канал на всю нативную часть. ОДНО ОПРЕДЕЛЕНИЕ НА ПРОЕКТ: имя
/// канала совпадает с константой в RichNotifications.kt, и разойтись им
/// нельзя — расхождение не падает, а тихо возвращает
/// MissingPluginException.
const MethodChannel nativeChannel = MethodChannel('chrolingo/native');

/// Есть ли нативная часть на этой платформе. iOS и тесты её не имеют.
bool get nativeSupported => !kIsWeb && Platform.isAndroid;

class RichNotification {
  RichNotification._();

  static bool get supported => nativeSupported;

  /// Показать немедленно. Возвращает false, если нативной части нет.
  static Future<bool> show(NotificationSpec spec) =>
      _call('show', jsonEncode(spec.toJson()));

  /// Заменить расписание целиком.
  ///
  /// ЦЕЛИКОМ, А НЕ ПО ОДНОМУ. Расписание пересобирается после каждого
  /// занятия и на каждом запуске; добавлять к старому значило бы
  /// получить вечером и новое напоминание, и вчерашнее.
  static Future<bool> schedule(List<NotificationSpec> plan) =>
      _call('schedule', jsonEncode([for (final s in plan) s.toJson()]));

  static Future<bool> cancelAll() => _call('cancelAll', null);

  static Future<bool> _call(String method, String? payload) async {
    if (!supported) return false;
    try {
      await nativeChannel.invokeMethod<bool>(method, payload);
      return true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('notification $method failed: $e');
      return false;
    }
  }
}
