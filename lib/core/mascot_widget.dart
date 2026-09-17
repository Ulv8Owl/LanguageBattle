/// Виджет на рабочем столе: настроение хамелеона, серия и время до
/// полуночи.
///
/// ═══ ЗАЧЕМ ОН, КОГДА ЕСТЬ УВЕДОМЛЕНИЯ ═══
///
/// Уведомление с Android 12 обязано нести шапку системы с именем
/// приложения: «For apps targeting Android 12, notifications with custom
/// content views will no longer use the full notification area; instead,
/// the system applies a standard template». У виджета такой шапки нет ни
/// у кого — всё пространство его, включая фон и высоту. Именно поэтому
/// «полноценная картинка», которую видно у Duolingo, — это виджет, а не
/// уведомление: у приложения в Google Play другого способа нет.
///
/// ═══ ЧЕМ ОН ОТЛИЧАЕТСЯ ОТ НАПОМИНАНИЯ ═══
///
/// Уведомление ПЕРЕБИВАЕТ, поэтому молчит, когда сказать нечего, и
/// торопит только поздним вечером. Виджет НЕ перебивает — на него
/// смотрят сами. Поэтому он говорит всегда (включая «на сегодня всё») и
/// показывает отсчёт весь день, пока серия догорает, а не последние три
/// часа.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/practice_diary.dart';
import '../data/reminder_templates.dart';
import 'native_ui.dart';

class MascotWidget {
  MascotWidget._();

  /// Пересчитать и отправить состояние виджета.
  ///
  /// Зовётся на запуске приложения и после каждого занятия. Отдельно от
  /// напоминаний НАРОЧНО: виджет висит на экране и тогда, когда
  /// напоминания выключены.
  static Future<void> refresh({int? energyMax}) async {
    if (!nativeSupported) return;
    final now = DateTime.now();
    final state = await PracticeDiary.state(now: now, energyMax: energyMax);

    // Серия догорает СЕГОДНЯ: занимался вчера, сегодня ещё нет. Для
    // виджета этого достаточно — в отличие от уведомления, ему не нужно
    // дожидаться вечера, чтобы показать отсчёт: он никого не перебивает.
    final burning = state.streakDays > 0 && state.daysSincePractice == 1;
    final reminder =
        state.practisedToday ? doneTodayReminder(state) : pickReminder(state)!;

    try {
      await nativeChannel.invokeMethod<bool>(
        'widget',
        jsonEncode({
          'title': reminder.title,
          'body': reminder.body,
          'mascot': reminder.mascotResource,
          'skin': state.practisedToday
              ? 'ok'
              : burning
                  ? 'ember'
                  : 'gold',
          'countdownUntil': burning
              ? DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch
              : null,
        }),
      );
    } catch (e) {
      // Виджета может не быть вовсе — его ставит игрок, и большинство не
      // ставит никогда. Это не повод ронять запуск приложения.
      debugPrint('widget update failed: $e');
    }
  }
}
