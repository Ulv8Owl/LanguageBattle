/// Мост к уведомлению со своей разметкой и к будильникам Android
/// (android/.../ChrolingoNotification.kt, ReminderAlarms.kt).
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

  /// Файл картинки настроения НА ДИСКЕ. Именно файл: вечером ассеты
  /// Flutter прочитать некому.
  final String? imagePath;

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
    this.imagePath,
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
        'imagePath': imagePath,
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

class RichNotification {
  RichNotification._();

  static const MethodChannel _channel = MethodChannel('chrolingo/notifications');

  static bool get supported => !kIsWeb && Platform.isAndroid;

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
      await _channel.invokeMethod<bool>(method, payload);
      return true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('notification $method failed: $e');
      return false;
    }
  }
}
