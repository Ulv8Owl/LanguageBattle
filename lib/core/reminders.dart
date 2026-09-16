/// Напоминания зайти позаниматься — местные, без сервера и без пуша.
///
/// ═══ ЧТО ИЗ ЭТОГО СДЕЛАНО «КАК У DUOLINGO», А ЧТО НЕТ ═══
///
/// Их уведомление выглядит как картинка с текстом. Картинка — это
/// `largeIcon`: система рисует её справа от текста, и ЭТО ЕДИНСТВЕННЫЙ
/// способ показать свой рисунок, оставшийся у приложений. Полностью своя
/// разметка уведомления запрещена с Android 12: система накрывает её
/// своим шаблоном (тем же, что у `DecoratedCustomViewStyle`). Поэтому
/// «полноценная картинка» — это набор ЗАРАНЕЕ НАРИСОВАННЫХ картинок, из
/// которого выбирается одна; ровно так же устроен и виджет Duolingo.
///
/// Цифры в их уведомлении НЕ нарисованы: заголовок обрезается системным
/// многоточием, а счётчик до полуночи тикает сам. Тикающий счётчик у нас
/// тоже есть — `usesChronometer` + `chronometerCountDown` (см. ниже): он
/// показывает, сколько осталось до потери серии, и обновляется сам, без
/// участия приложения.
///
/// ═══ ЗВУК ═══
///
/// Свой звук у канала, а не у уведомления, и поменять его у СУЩЕСТВУЮЩЕГО
/// канала нельзя — Android фиксирует звук в момент создания канала
/// («Only modifiable before the channel is submitted»). Поэтому в id
/// канала стоит номер версии: меняя звук, меняют и его, иначе игрок
/// продолжит слышать старый, и выглядеть это будет как «звук не
/// применился».
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/practice_diary.dart';
import '../data/reminder_templates.dart';
import 'local_timezone.dart';
import 'theme.dart';

/// id канала. МЕНЯТЬ ВМЕСТЕ СО ЗВУКОМ ИЛИ ВИБРАЦИЕЙ — см. выше.
const String kReminderChannelId = 'chrolingo.reminders.v1';

/// Имя файла в `android/app/src/main/res/raw` без расширения.
const String kReminderSound = 'reminder';

/// Значок в строке состояния: имя ресурса в `res/drawable-*`, БЕЗ
/// «@drawable/» и без расширения. Плагин ищет его через
/// `getIdentifier(name, "drawable", ...)`, и лишний префикс — это не
/// «не та картинка», а отказ на инициализации.
const String kReminderIcon = 'ic_notification';

/// На сколько дней вперёд раскладываются напоминания.
///
/// Приложение закрыто — назначать новые некому, поэтому назначаем сразу
/// неделю. Дальше недели молчания их подхватывает [_weeklyId].
const int kReminderHorizonDays = 7;

/// Час напоминания по умолчанию: вечер, но не ночь.
const int kReminderDefaultHour = 20;

const int _firstId = 4200;
const int _weeklyId = 4299;

const String _enabledKey = 'reminders.enabled';
const String _hourKey = 'reminders.hour';

class Reminders {
  Reminders._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _ready = false;

  /// Поднять плагин и канал. Зовётся из main до первого кадра; на
  /// платформах без поддержки молча ничего не делает.
  static Future<void> init() async {
    if (_ready || !_supported) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(kReminderIcon),
        // НАСТРОЙКИ iOS ОБЯЗАТЕЛЬНЫ, ДАЖЕ ЕСЛИ iOS НЕ СОБИРАЮТ: без них
        // initialize БРОСАЕТ на этой платформе, и приложение падает на
        // запуске. Разрешения здесь не просим — их спрашивают, когда
        // игрок включает напоминания, а не когда открывает приложение.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        kReminderChannelId,
        'Напоминания',
        description: 'Зайти позаниматься и не потерять серию.',
        importance: Importance.high,
        sound: RawResourceAndroidNotificationSound(kReminderSound),
      ),
    );
    ensureTimeZoneData();
    tz.setLocalLocation(resolveLocalLocation());
    _ready = true;
  }

  static bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

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
    if (!_supported) return false;
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission() ??
        await ios?.requestPermissions(alert: true, sound: true, badge: true) ??
        false;
    if (!granted) return false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, true);
    if (atHour != null) await prefs.setInt(_hourKey, atHour);
    await refresh();
    return true;
  }

  static Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    if (!_supported) return;
    await init();
    await _plugin.cancelAll();
  }

  /// Переназначить всё расписание заново.
  ///
  /// ВЫЗЫВАЕТСЯ ЧАСТО И НАМЕРЕННО: на запуске приложения и после каждого
  /// занятия. Уведомление, назначенное вчера, ничего не знает о том, что
  /// игрок уже позанимался, — а лишнее «вы сегодня не занимались» после
  /// занятия это ровно тот случай, когда уведомления отключают целиком.
  static Future<void> refresh({int? energyMax}) async {
    if (!_supported) return;
    if (!await isEnabled()) return;
    await init();
    await _plugin.cancelAll();

    final atHour = await hour();
    final now = DateTime.now();
    final today = await PracticeDiary.state(now: now, energyMax: energyMax);
    final recent = [...await PracticeDiary.recentReminders()];
    final planned = <String>[];

    for (var day = 0; day < kReminderHorizonDays; day++) {
      final when = DateTime(now.year, now.month, now.day + day, atHour);
      // Сегодняшний час уже прошёл — сегодня и промолчим: уведомление
      // «в прошлом» система показывает немедленно, посреди занятия.
      if (!when.isAfter(now)) continue;
      final state = projectState(today, day, atHour);
      final reminder = pickReminder(state, recentIds: recent);
      if (reminder == null) continue;
      recent.add(reminder.id);
      planned.add(reminder.id);
      await _schedule(
        id: _firstId + day,
        at: when,
        reminder: reminder,
        state: state,
      );
    }

    await _scheduleWeeklyTail(
        now: now, hour: atHour, energyMax: today.energyMax);
    if (planned.isNotEmpty) {
      await PracticeDiary.rememberReminders(
        [...await PracticeDiary.recentReminders(), ...planned],
      );
    }
  }

  /// Хвост на случай, если приложение не откроют неделю.
  ///
  /// Назначать дальше горизонта поимённо бессмысленно: пересобрать их
  /// всё равно будет некому. Поэтому одно ПОВТОРЯЮЩЕЕСЯ раз в неделю, в
  /// тот же час, и без единой цифры внутри — цифра протухла бы в первую
  /// же неделю (см. [longSilenceReminder]). Молчать вместо него нельзя:
  /// неделя молчания — это и есть тот момент, ради которого напоминания
  /// существуют.
  static Future<void> _scheduleWeeklyTail({
    required DateTime now,
    required int hour,
    required int energyMax,
  }) async {
    final state = ReminderState(
      daysSincePractice: kReminderHorizonDays + 1,
      streakDays: 0,
      hour: hour,
      energy: energyMax,
      energyMax: energyMax,
    );
    final reminder = longSilenceReminder();
    final when = DateTime(
      now.year,
      now.month,
      now.day + kReminderHorizonDays + 1,
      hour,
    );
    await _schedule(
      id: _weeklyId,
      at: when,
      reminder: reminder,
      state: state,
      repeatWeekly: true,
    );
  }

  static Future<void> _schedule({
    required int id,
    required DateTime at,
    required Reminder reminder,
    required ReminderState state,
    bool repeatWeekly = false,
    bool showNow = false,
  }) async {
    final picture = await _materialize(reminder.imageAsset);
    // Счётчик до полуночи — ровно то, что тикает в уведомлениях
    // Duolingo. Его считает СИСТЕМА от заданного момента, поэтому он
    // остаётся верным и через час после прихода уведомления, когда
    // «осталось 4 часа» в тексте давно устарело бы.
    final burning = state.streakDays > 0 && state.daysSincePractice == 1;
    final midnight = DateTime(at.year, at.month, at.day + 1);

    final details = AndroidNotificationDetails(
      kReminderChannelId,
      'Напоминания',
      channelDescription: 'Зайти позаниматься и не потерять серию.',
      importance: Importance.high,
      priority: Priority.high,
      color: AppColors.gold,
      largeIcon: picture == null ? null : FilePathAndroidBitmap(picture),
      styleInformation: BigTextStyleInformation(
        reminder.body,
        contentTitle: reminder.title,
      ),
      subText: state.streakDays > 0 ? '🔥 ${state.streakDays}' : null,
      when: burning ? midnight.millisecondsSinceEpoch : null,
      usesChronometer: burning,
      chronometerCountDown: burning,
      category: AndroidNotificationCategory.reminder,
    );

    // На iOS та же картинка живёт вложением: своего «largeIcon» там нет,
    // а вложенный файл система показывает превью справа от текста.
    final darwin = DarwinNotificationDetails(
      attachments: picture == null
          ? null
          : [DarwinNotificationAttachment(picture)],
    );

    if (showNow) {
      await _plugin.show(
        id: id,
        title: reminder.title,
        body: reminder.body,
        notificationDetails:
            NotificationDetails(android: details, iOS: darwin),
      );
      return;
    }

    await _plugin.zonedSchedule(
      id: id,
      title: reminder.title,
      body: reminder.body,
      scheduledDate: _wallClock(at),
      notificationDetails: NotificationDetails(android: details, iOS: darwin),
      // ТОЧНОЕ ВРЕМЯ ЗДЕСЬ НЕ НУЖНО, а разрешение под него нужно было бы
      // спрашивать отдельно (SCHEDULE_EXACT_ALARM, Android 14). «Около
      // восьми вечера» — ровно та точность, которой хватает напоминанию.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents:
          repeatWeekly ? DateTimeComponents.dayOfWeekAndTime : null,
    );
  }

  /// Показать напоминание прямо сейчас — проверить звук и картинку.
  ///
  /// БЕЗ ЭТОГО ПРОВЕРИТЬ НЕЧЕМ. Настоящее уведомление приходит вечером и
  /// только если игрок не занимался; ждать до вечера, чтобы узнать, что
  /// звук не тот, — это один день на один ответ.
  static Future<void> preview() async {
    if (!_supported) return;
    await init();
    final state = await PracticeDiary.state();
    // Занимался сегодня — напоминания нет и быть не должно, но показать
    // ЧТО-ТО надо: проверяют же оформление, а не правила.
    final reminder = pickReminder(state) ??
        pickReminder(projectState(state, 1, DateTime.now().hour))!;
    await _schedule(
      id: _firstId - 1,
      at: DateTime.now(),
      reminder: reminder,
      state: state,
      showNow: true,
    );
  }

  /// «Двадцать часов у игрока» — именно как показания часов, а не как
  /// момент времени.
  ///
  /// РАЗНИЦА НЕ УМОЗРИТЕЛЬНАЯ. `TZDateTime.from` переводит МОМЕНТ в
  /// другую зону: двадцать часов превратятся в двадцать один, если
  /// смещения разойдутся хоть на час. А `TZDateTime(...)` строит
  /// показания часов прямо в нужной зоне — и остаётся двадцатью часами
  /// и до перевода стрелок, и после.
  static tz.TZDateTime _wallClock(DateTime at) => tz.TZDateTime(
        tz.local,
        at.year,
        at.month,
        at.day,
        at.hour,
        at.minute,
      );

  /// Скопировать картинку из ассетов в файл: `largeIcon` принимает файл
  /// или ресурс Android, а ассет Flutter не является ни тем, ни другим.
  static Future<String?> _materialize(String assetKey) async {
    try {
      final dir = Directory(
          '${(await getApplicationSupportDirectory()).path}/notifications');
      await dir.create(recursive: true);
      final file = File('${dir.path}/${assetKey.split('/').last}');
      final data = await rootBundle.load(assetKey);
      final bytes = data.buffer.asUint8List();
      if (!file.existsSync() || file.lengthSync() != bytes.length) {
        await file.writeAsBytes(bytes, flush: true);
      }
      return file.path;
    } catch (e) {
      // Без картинки уведомление всё равно придёт — с текстом. Ронять
      // напоминание из-за оформления нельзя.
      debugPrint('mascot image unavailable: $e');
      return null;
    }
  }
}
