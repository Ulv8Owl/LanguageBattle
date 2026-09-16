/// Дневник занятий: какие дни игрок занимался и что ему уже писали.
///
/// ═══ ПОЧЕМУ ЭТО ЖИВЁТ НА ТЕЛЕФОНЕ, А НЕ НА СЕРВЕРЕ ═══
///
/// Всё остальное, что похоже на прогресс, считает сервер — и правильно
/// делает. Но напоминание — это не прогресс. Его показывает телефон,
/// когда приложение закрыто, и ему нужен ответ на один вопрос: писать
/// сейчас или молчать. Спросить сервер в этот момент нельзя: сети может
/// не быть, а будильник уже сработал. Поэтому дни занятий телефон
/// запоминает сам.
///
/// Разойтись с сервером эта запись не может по устройству: она не
/// начисляет и не тратит НИЧЕГО. Потерялась при переустановке — игрок
/// получит «самое время начать», а не потерянные монеты.
///
/// ═══ ЧТО СЧИТАЕТСЯ ЗАНЯТИЕМ ═══
///
/// Отправленная запись голоса: и бой, и одиночная игра проходят через
/// `submitVoiceRecording`. Это единственное место, где игрок ГОВОРИТ, и
/// единственное, за что он платит энергией. Открытое приложение занятием
/// не считается — иначе серия держалась бы сама собой.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../core/game_access.dart';
import 'reminder_templates.dart';

/// Ключ дня в местном времени. Именно местного: полночь — это полночь у
/// игрока, а не в UTC, иначе серия обрывалась бы посреди вечера.
String dayKey(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-'
    '${local.month.toString().padLeft(2, '0')}-'
    '${local.day.toString().padLeft(2, '0')}';

/// Сколько дней прошло с последнего занятия. 0 — занимался сегодня.
///
/// ПУСТОЙ ДНЕВНИК — ЭТО 1, А НЕ БЕСКОНЕЧНОСТЬ. Новичок, поставивший
/// приложение вчера, не «пропал на 20000 дней»: ему нужно «самое время
/// начать», и единица приводит его ровно туда.
int daysSincePractice(List<String> days, DateTime today) {
  if (days.isEmpty) return 1;
  final sorted = [...days]..sort();
  final last = DateTime.tryParse(sorted.last);
  if (last == null) return 1;
  final from = DateTime(last.year, last.month, last.day);
  final to = DateTime(today.year, today.month, today.day);
  final diff = to.difference(from).inDays;
  return diff < 0 ? 0 : diff;
}

/// Длина серии: сколько дней подряд игрок занимался, считая назад от
/// последнего занятия.
///
/// СЕРИЯ, КОТОРАЯ УЖЕ СГОРЕЛА, РАВНА НУЛЮ. Последнее занятие позавчера —
/// серии нет, сколько бы дней подряд до этого ни было: вчерашняя полночь
/// её и забрала. А занятие ВЧЕРА серию ещё не рвёт — она догорает
/// сегодня, и это единственный повод торопить игрока.
int practiceStreak(List<String> days, DateTime today) {
  if (days.isEmpty) return 0;
  final have = days.toSet();
  final since = daysSincePractice(days, today);
  if (since > 1) return 0;

  var at = DateTime(today.year, today.month, today.day)
      .subtract(Duration(days: since));
  var streak = 0;
  while (have.contains(dayKey(at))) {
    streak++;
    at = at.subtract(const Duration(days: 1));
  }
  return streak;
}

class PracticeDiary {
  PracticeDiary._();

  static const _daysKey = 'practice.days';
  static const _recentKey = 'practice.recentReminders';

  /// Сколько дней держим. Больше года назад не нужно никому: серию
  /// считают назад до первого пропуска, а он случается раньше.
  static const _keepDays = 400;

  /// Сколько последних напоминаний помним, чтобы не повторяться.
  static const keepRecent = 6;

  /// Отметить, что игрок сегодня занимался.
  ///
  /// Вызывается из [submitVoiceRecording] и НИЧЕГО не ждёт: запись в
  /// настройки не должна ни задержать отправку, ни уронить её.
  static Future<void> markPractised({DateTime? when}) async {
    final today = dayKey(when ?? DateTime.now());
    final prefs = await SharedPreferences.getInstance();
    final days = prefs.getStringList(_daysKey) ?? const <String>[];
    if (days.contains(today)) return;
    final next = [...days, today]..sort();
    await prefs.setStringList(
      _daysKey,
      next.length > _keepDays ? next.sublist(next.length - _keepDays) : next,
    );
  }

  static Future<List<String>> days() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_daysKey) ?? const <String>[];
  }

  /// Идентификаторы последних отправленных напоминаний, свежие в конце.
  static Future<List<String>> recentReminders() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_recentKey) ?? const <String>[];
  }

  static Future<void> rememberReminders(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final kept = ids.length > keepRecent
        ? ids.sublist(ids.length - keepRecent)
        : ids;
    await prefs.setStringList(_recentKey, kept);
  }

  /// Состояние игрока на сейчас — то, из чего выбирается напоминание.
  ///
  /// [energyMax] берётся из последнего ответа сервера; не знаем — берём
  /// потолок по умолчанию, тот же, что рисует клиент до ответа.
  static Future<ReminderState> state({DateTime? now, int? energyMax}) async {
    final at = now ?? DateTime.now();
    final recorded = await days();
    final max = energyMax ?? WalletState.empty.energyMax;
    return ReminderState(
      daysSincePractice: daysSincePractice(recorded, at),
      streakDays: practiceStreak(recorded, at),
      hour: at.hour,
      // ЭНЕРГИЯ В БУДУЩЕМ ВСЕГДА ПОЛНАЯ, и это не допущение, а арифметика:
      // восстанавливается она по одной за десять секунд (миграция 0053),
      // то есть полный запас набирается за минуты. Любое напоминание
      // назначается минимум на часы вперёд — к тому моменту запас полон,
      // чем бы он ни был сейчас.
      energy: max,
      energyMax: max,
    );
  }
}
