/// Напоминания зайти позаниматься — местные, без сервера и без пуша.
///
/// ═══ ЧТО ИЗ ЭТОГО СДЕЛАНО «КАК У DUOLINGO», А ЧТО НЕТ ═══
///
/// Их уведомление выглядит как картинка с текстом. Картинка — это набор
/// ЗАРАНЕЕ НАРИСОВАННЫХ рисунков, из которого выбирается один по
/// состоянию игрока; так же устроен и их виджет. Цифры НЕ нарисованы:
/// заголовок обрезается системным многоточием, а счётчик до полуночи
/// тикает сам. Такой счётчик есть и у нас — `Chronometer` внутри своей
/// разметки, его считает система.
///
/// Чего у нас нет и быть не может, пока `targetSdk >= 31`, — уведомления
/// БЕЗ ШАПКИ: «For apps targeting Android 12, notifications with custom
/// content views will no longer use the full notification area; instead,
/// the system applies a standard template».
///
/// ═══ ПОЧЕМУ ВСЁ РИСУЕТ ОДИН КОД ═══
///
/// И «показать сейчас», и вечернее напоминание собираются одним
/// [NotificationSpec] и рисуются одним ChrolingoNotification.kt. Пока
/// это было не так — расписание ставил плагин системным шаблоном, а
/// превью рисовало своё, — кнопка проверки показывала не то, что придёт
/// вечером. Проверка, показывающая другое, хуже отсутствующей.
library;

import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/practice_diary.dart';
import '../data/reminder_templates.dart';
import 'native_ui.dart';

/// id канала обычных напоминаний.
///
/// МЕНЯТЬ ВМЕСТЕ СО ЗВУКОМ ИЛИ ВИБРАЦИЕЙ. Android запоминает их при
/// СОЗДАНИИ канала и менять у существующего не даёт («Only modifiable
/// before the channel is submitted»). Сменили звук, не сменив id, —
/// игрок продолжит слышать старый.
const String kReminderChannelId = 'chrolingo.reminders.v1';

/// Канал срочного напоминания — «серия сгорит сегодня».
///
/// ОТДЕЛЬНЫЙ НАРОЧНО. Важность канала задаёт игрок, и она у него одна на
/// канал: отключив надоевшие вечерние напоминания, он вместе с ними
/// отключил бы и единственное, которое стоит показать поверх остальных.
const String kStreakChannelId = 'chrolingo.streak.v1';

/// Имя файла в `android/app/src/main/res/raw` без расширения.
const String kReminderSound = 'reminder';

/// Значок в строке состояния: имя ресурса в `res/drawable-*`, БЕЗ
/// «@drawable/» и без расширения — так его ищет `getIdentifier`.
const String kReminderIcon = 'ic_notification';

/// На сколько дней вперёд раскладываются напоминания.
const int kReminderHorizonDays = 7;

/// Час напоминания по умолчанию: вечер, но не ночь.
const int kReminderDefaultHour = 20;

const int _firstId = 4200;
const int _weeklyId = 4299;
const int _previewId = 4199;
const int _streakPreviewId = 4198;

const String _enabledKey = 'reminders.enabled';
const String _hourKey = 'reminders.hour';

class Reminders {
  Reminders._();

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  static Future<int> hour() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_hourKey) ?? kReminderDefaultHour;
  }

  /// Запомнить час, ничего не назначая. Нужно, когда время выбрали при
  /// выключенных напоминаниях: включат позже — час уже будет тот.
  static Future<void> setHour(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_hourKey, value);
  }

  /// Включить напоминания. Возвращает false, если разрешение не дали —
  /// тогда переключатель обязан вернуться в «выключено», а не врать.
  static Future<bool> enable({int? atHour}) async {
    if (!RichNotification.supported) return false;
    // С Android 13 без этого права уведомления не показываются вовсе, и
    // спросить его обязано приложение.
    final status = await Permission.notification.request();
    if (!status.isGranted) return false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, true);
    if (atHour != null) await prefs.setInt(_hourKey, atHour);
    await refresh();
    return true;
  }

  static Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    await RichNotification.cancelAll();
  }

  /// Переназначить всё расписание заново.
  ///
  /// ВЫЗЫВАЕТСЯ ЧАСТО И НАМЕРЕННО: на запуске приложения и после каждого
  /// занятия. Будильник, заведённый вчера, ничего не знает о том, что
  /// игрок уже позанимался, — а лишнее «вы сегодня не занимались» после
  /// занятия это ровно тот случай, когда уведомления отключают целиком.
  static Future<void> refresh({int? energyMax}) async {
    if (!RichNotification.supported) return;
    if (!await isEnabled()) {
      await RichNotification.cancelAll();
      return;
    }

    final atHour = await hour();
    final now = DateTime.now();
    final today = await PracticeDiary.state(now: now, energyMax: energyMax);
    final recent = [...await PracticeDiary.recentReminders()];
    final planned = <String>[];
    final plan = <NotificationSpec>[];

    for (var day = 0; day < kReminderHorizonDays; day++) {
      final when = DateTime(now.year, now.month, now.day + day, atHour);
      // Сегодняшний час уже прошёл — сегодня и промолчим: будильник в
      // прошлом система показывает немедленно, посреди занятия.
      if (!when.isAfter(now)) continue;
      final state = projectState(today, day, atHour);
      final reminder = pickReminder(state, recentIds: recent);
      if (reminder == null) continue;
      recent.add(reminder.id);
      planned.add(reminder.id);
      plan.add(_spec(
        id: _firstId + day,
        reminder: reminder,
        state: state,
        at: when,
      ));
    }

    plan.add(_longSilenceSpec(now: now, atHour: atHour, from: today));

    await RichNotification.schedule(plan);
    if (planned.isNotEmpty) {
      await PracticeDiary.rememberReminders(
        [...await PracticeDiary.recentReminders(), ...planned],
      );
    }
  }

  /// Хвост на случай, если приложение не откроют неделю.
  ///
  /// Назначать дальше горизонта поимённо бессмысленно: пересобрать их
  /// всё равно будет некому. Поэтому одно ПОВТОРЯЮЩЕЕСЯ раз в неделю и
  /// без единой цифры внутри — цифра протухла бы в первую же неделю.
  /// Молчать вместо него нельзя: неделя молчания — это и есть тот
  /// момент, ради которого напоминания существуют.
  static NotificationSpec _longSilenceSpec({
    required DateTime now,
    required int atHour,
    required ReminderState from,
  }) =>
      _spec(
        id: _weeklyId,
        reminder: longSilenceReminder(),
        state: ReminderState(
          daysSincePractice: kReminderHorizonDays + 1,
          streakDays: 0,
          hour: atHour,
          energy: from.energy,
          energyMax: from.energyMax,
        ),
        at: DateTime(
          now.year,
          now.month,
          now.day + kReminderHorizonDays + 1,
          atHour,
        ),
        repeatWeekly: true,
      );

  /// Показать обычное напоминание прямо сейчас — проверить вид, звук и
  /// картинку.
  ///
  /// БЕЗ ЭТОГО ПРОВЕРИТЬ НЕЧЕМ. Настоящее приходит вечером и только если
  /// игрок не занимался; ждать до вечера, чтобы узнать, что звук не тот,
  /// — это один день на один ответ.
  static Future<void> preview() async {
    final state = await PracticeDiary.state();
    // Занимался сегодня — напоминания нет и быть не должно, но показать
    // ЧТО-ТО надо: проверяют оформление, а не правила.
    final reminder = pickReminder(state) ??
        pickReminder(projectState(state, 1, DateTime.now().hour))!;
    await RichNotification.show(
      _spec(id: _previewId, reminder: reminder, state: state),
    );
  }

  /// Показать срочное напоминание — с живым отсчётом до полуночи, на
  /// другой подложке и поверх остальных.
  static Future<void> previewStreak() async {
    final diary = await PracticeDiary.state();
    // Серии может не быть вовсе, а показать надо именно срочное. Берём
    // состояние «вчера занимался, серия жива, поздний вечер»: ровно то,
    // ради чего это уведомление и существует.
    final state = ReminderState(
      daysSincePractice: 1,
      streakDays: diary.streakDays > 0 ? diary.streakDays : 1,
      hour: 21,
      energy: diary.energy,
      energyMax: diary.energyMax,
    );
    await RichNotification.show(
      _spec(id: _streakPreviewId, reminder: pickReminder(state)!, state: state),
    );
  }

  /// Одно напоминание целиком: и для показа сейчас, и для будильника.
  static NotificationSpec _spec({
    required int id,
    required Reminder reminder,
    required ReminderState state,
    DateTime? at,
    bool repeatWeekly = false,
  }) {
    // Серия догорает именно сегодня — единственный повод торопить и
    // единственный, где счётчик до полуночи что-то значит.
    final burning = state.streakDays > 0 &&
        state.daysSincePractice == 1 &&
        state.lateEvening;
    final day = at ?? DateTime.now();

    return NotificationSpec(
      id: id,
      channelId: burning ? kStreakChannelId : kReminderChannelId,
      channelName: burning ? 'Серия сгорает' : 'Напоминания',
      sound: kReminderSound,
      title: reminder.title,
      // В срочном виде заголовок уступает место крупным цифрам, поэтому
      // текст обязан читаться сам по себе — и не спорить с таймером.
      body: burning ? burningBody(state) : reminder.body,
      mascot: reminder.mascotResource,
      skin: burning ? NotificationSkin.ember : NotificationSkin.gold,
      countdownUntil:
          burning ? DateTime(day.year, day.month, day.day + 1) : null,
      at: at,
      repeatWeekly: repeatWeekly,
    );
  }

}
