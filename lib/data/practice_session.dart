/// «Занятие состоялось» — одна точка на все режимы.
///
/// ═══ ПОЧЕМУ ОДНА ═══
///
/// Отметить занятие надо в трёх местах сразу: на сервере (он считает
/// серию и он один вправе это делать), в местном дневнике (вечером, когда
/// уведомление решает «писать или молчать», сети может не быть) и в
/// виджете с напоминаниями (иначе вечером придёт «сегодня не занимались»
/// тому, кто занимался утром). Три вызова, разложенные по экранам,
/// однажды разойдутся — и разойдутся молча.
///
/// ═══ ГДЕ ЭТО ЗОВУТ ═══
///
/// Там, где игрок ЗАКОНЧИЛ, а не начал: серия за открытый экран — не
/// серия. Бой и одиночная — на отправке записи, аудирование — на конце
/// дорожки.
library;

import 'package:flutter/foundation.dart';

import '../core/mascot_widget.dart';
import '../core/reminders.dart';
import 'practice_diary.dart';
import 'streaks.dart';

/// Отметить занятие. НИЧЕГО НЕ ЖДЁТ И НЕ РОНЯЕТ: уронить отправку записи
/// или конец дорожки из-за серии значило бы обменять ценное на
/// украшение.
Future<StreakState?> countAsPractice(PracticeMode mode) async {
  await PracticeDiary.markPractised();
  StreakState? streak;
  try {
    streak = await Streaks.record(mode);
    await PracticeDiary.adoptServerStreak(
      current: streak.current,
      lastDay: DateTime.now(),
    );
  } catch (e) {
    // Сети нет или языка не выбрано — день всё равно записан на
    // телефоне, и сервер догонит при следующем занятии.
    debugPrint('streak not recorded: $e');
  }
  await Reminders.refresh();
  await MascotWidget.refresh();
  return streak;
}
