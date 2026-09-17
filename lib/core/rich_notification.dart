/// Мост к уведомлению со своей разметкой (android/.../RichNotifications.kt).
///
/// ПОЧЕМУ НЕ ПЛАГИН. flutter_local_notifications умеет только системные
/// шаблоны: заголовок, текст, картинка справа. Ни залить плашку цветом,
/// ни поставить крупный тикающий счётчик он не может — для этого нужна
/// своя RemoteViews-разметка, а её плагин не пробрасывает.
///
/// ЧЕГО НЕ МОЖЕТ И ЭТОТ МОСТ: убрать из шапки имя приложения. С Android
/// 12 приложение не рисует уведомление целиком — система накрывает его
/// своим шаблоном, и шапка принадлежит ей. Штамп «Сейчас» рядом с именем
/// убирается (`setShowWhen(false)`), само имя — нет.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Расцветка плашки. Имена совпадают с картой SKINS в
/// RichNotifications.kt — по ним же ищутся и фоны в res/drawable.
enum NotificationSkin {
  /// Обычное напоминание: золотая плашка, тёмный текст.
  gold,

  /// Срочное: «серия сгорит сегодня».
  ember,
}

class RichNotification {
  RichNotification._();

  static const MethodChannel _channel = MethodChannel('chrolingo/notifications');

  /// Показать уведомление немедленно.
  ///
  /// Возвращает false, если своей разметки на этой платформе нет (iOS,
  /// тесты, старый APK без нативной части). ВОЗВРАЩАЕТ, А НЕ БРОСАЕТ:
  /// звать её умеет только тот, у кого есть запасной путь.
  static Future<bool> show({
    required int id,
    required String channelId,
    required String channelName,
    required String title,
    required String body,
    String? sound,
    String? imagePath,
    NotificationSkin skin = NotificationSkin.gold,
    DateTime? countdownUntil,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      await _channel.invokeMethod<bool>('show', <String, dynamic>{
        'id': id,
        'channelId': channelId,
        'channelName': channelName,
        'title': title,
        'body': body,
        'sound': sound,
        'imagePath': imagePath,
        'skin': skin.name,
        'countdownUntil': countdownUntil?.millisecondsSinceEpoch,
      });
      return true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('rich notification failed: $e');
      return false;
    }
  }
}
