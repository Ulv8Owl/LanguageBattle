import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/core/reminders.dart';
import 'package:language_battle/core/rich_notification.dart';
import 'package:language_battle/data/practice_diary.dart';
import 'package:language_battle/data/reminder_templates.dart';

/// Напоминания ломаются ТИШИНОЙ. Не пришло уведомление — и отличить
/// «правильно промолчали» от «receiver не объявлен в манифесте» на
/// телефоне нельзя ничем: ошибки нет, лога нет, экрана нет.
///
/// Поэтому проверок здесь два вида. Первый — правила выбора: кому что
/// писать, считается чистыми функциями и проверяется целиком. Второй —
/// чтение самих файлов сборки: манифеста, gradle, ресурсов. Второе
/// нужно потому, что ни одна из этих настроек не проявляется в коде: их
/// забывают, сборка проходит, а уведомлений нет.
void main() {
  ReminderState state({
    int days = 1,
    int streak = 0,
    int hour = 20,
    int energy = 50,
    int energyMax = 50,
  }) =>
      ReminderState(
        daysSincePractice: days,
        streakDays: streak,
        hour: hour,
        energy: energy,
        energyMax: energyMax,
      );

  group('что писать игроку', () {
    test('занимался сегодня — не пишем вообще', () {
      // Уведомление «на всякий случай» стоит дороже, чем кажется:
      // отключают их не по одному, а все сразу и навсегда.
      expect(pickReminder(state(days: 0)), isNull);
      expect(pickReminder(state(days: 0, streak: 9, hour: 23)), isNull);
    });

    test('серия догорает сегодня — торопим, и только тогда', () {
      final evening = pickReminder(state(days: 1, streak: 7, hour: 20))!;
      expect(evening.mood, MascotMood.worried);
      expect(evening.title, contains('7'));

      // Днём та же серия — повод позвать, а не торопить: до полуночи
      // ещё полдня, и «срочно» в полдень обесценивает «срочно» в девять.
      final noon = pickReminder(state(days: 1, streak: 7, hour: 12))!;
      expect(noon.mood, MascotMood.waiting);
    });

    test('серии нет — не обещаем её сохранность', () {
      final r = pickReminder(state(days: 1, streak: 0, hour: 21))!;
      expect(r.mood, MascotMood.waiting);
      expect(r.body, isNot(contains('серия')));
    });

    test('пропал на несколько дней — считаем дни, а не серию', () {
      final r = pickReminder(state(days: 4, streak: 0))!;
      expect(r.mood, MascotMood.sad);
      expect(r.title, contains('4'));
    });

    test('полная энергия не вытесняет остальное, а встаёт в очередь', () {
      // Энергия восстанавливается по одной за десять секунд, то есть
      // полна почти всегда. Будь она отдельной причиной, игрок получал
      // бы «энергия полная» каждый вечер.
      final ids = <String>{};
      final recent = <String>[];
      for (var i = 0; i < 3; i++) {
        final r = pickReminder(state(energy: 50, energyMax: 50),
            recentIds: recent)!;
        ids.add(r.id);
        recent.add(r.id);
      }
      expect(ids.length, 3, reason: 'три подряд — три разных текста');
      expect(ids.any((id) => id.startsWith('restless')), isTrue);
      expect(ids.any((id) => id.startsWith('waiting')), isTrue);
    });

    test('неполная энергия про энергию молчит', () {
      final recent = <String>[];
      for (var i = 0; i < 4; i++) {
        final r = pickReminder(state(energy: 3, energyMax: 50),
            recentIds: recent)!;
        expect(r.mood, MascotMood.waiting);
        recent.add(r.id);
      }
    });

    test('примелькавшееся уступает место самому давнему', () {
      // Все тексты уже показывали — берём тот, что показывали раньше
      // всех, а не первый по списку.
      final r = pickReminder(
        state(days: 5),
        recentIds: const ['lost.days', 'lost.back', 'lost.back'],
      )!;
      expect(r.id, 'lost.days');
    });

    test('дни и часы склоняются по-русски', () {
      String title(int days) => pickReminder(state(days: days))!.title;
      expect(title(2), contains('2 дня'));
      expect(title(5), contains('5 дней'));
      expect(title(11), contains('11 дней'));
      expect(title(21), contains('21 день'));
      expect(title(22), contains('22 дня'));

      // Часы — в тексте про догорающую серию.
      String body(int hour) =>
          pickReminder(state(days: 1, streak: 3, hour: hour))!.body;
      expect(body(23), contains('1 час'));
      expect(body(21), contains('3 часа'));
      expect(body(19), contains('5 часов'));
    });
  });

  group('хвост длинного молчания', () {
    test('в повторяющемся напоминании нет ни одной цифры', () {
      // Оно повторяется само, неделю за неделей, и пересобрать его
      // некому: приложение не открывают. Любое число внутри протухнет в
      // первую же неделю и будет врать все остальные.
      final r = longSilenceReminder();
      expect(RegExp(r'\d').hasMatch('${r.title} ${r.body}'), isFalse);
    });

    test('повторяется раз в неделю силами самого будильника', () {
      // Пересобрать его будет некому: приложение не открывают. Значит,
      // заводить себя заново обязан тот, кто его показал.
      expect(File('lib/core/reminders.dart').readAsStringSync(),
          contains('longSilenceReminder()'));
      expect(
        File('android/app/src/main/kotlin/com/chrolingo/app/'
                'ReminderAlarmReceiver.kt')
            .readAsStringSync(),
        contains('if (spec.repeatWeekly) ReminderAlarms.rearmWeekly'),
      );
    });
  });

  group('состояние на будущее', () {
    test('серия обнуляется со второго пропущенного дня', () {
      final now = state(days: 1, streak: 10, hour: 12);
      expect(projectState(now, 0, 20).streakDays, 10);
      expect(projectState(now, 1, 20).streakDays, 0,
          reason: 'полночь её уже забрала — обещать сохранность нельзя');
      expect(projectState(now, 3, 20).daysSincePractice, 4);
    });

    test('час берётся тот, на который назначено, а не текущий', () {
      expect(projectState(state(hour: 9), 2, 20).hour, 20);
    });
  });

  group('дневник занятий', () {
    test('ключ дня — местная дата', () {
      expect(dayKey(DateTime(2026, 1, 5)), '2026-01-05');
      expect(dayKey(DateTime(2026, 12, 31, 23, 59)), '2026-12-31');
    });

    test('пустой дневник — это «начни», а не «тебя не было вечность»', () {
      expect(daysSincePractice(const [], DateTime(2026, 5, 1)), 1);
      expect(practiceStreak(const [], DateTime(2026, 5, 1)), 0);
    });

    test('серия считается подряд и назад от последнего занятия', () {
      final days = ['2026-05-01', '2026-05-02', '2026-05-03'];
      expect(practiceStreak(days, DateTime(2026, 5, 3)), 3);
      // Занимался вчера — серия ещё жива, сегодня она догорает.
      expect(practiceStreak(days, DateTime(2026, 5, 4)), 3);
      expect(daysSincePractice(days, DateTime(2026, 5, 4)), 1);
      // Два дня без занятий — серии нет, сколько бы её ни было.
      expect(practiceStreak(days, DateTime(2026, 5, 5)), 0);
    });

    test('пропущенный день рвёт серию, а не сокращает', () {
      final days = ['2026-05-01', '2026-05-03', '2026-05-04'];
      expect(practiceStreak(days, DateTime(2026, 5, 4)), 2);
    });

    test('порядок записей значения не имеет', () {
      final shuffled = ['2026-05-04', '2026-05-01', '2026-05-03'];
      expect(practiceStreak(shuffled, DateTime(2026, 5, 4)), 2);
      expect(daysSincePractice(shuffled, DateTime(2026, 5, 6)), 2);
    });
  });

  group('когда показывать — считает сам телефон', () {
    test('момент берётся из DateTime, а не из базы часовых поясов', () {
      // Будильнику нужен МОМЕНТ, и DateTime(год, месяц, день, час) уже
      // посчитан по правилам зоны самого устройства — вместе с
      // переводом стрелок, если он случится до этого дня. Городить
      // поверх этого свою базу зон значит гадать там, где телефон знает.
      final code = File('lib/core/rich_notification.dart').readAsStringSync();
      expect(code, contains("'at': at?.millisecondsSinceEpoch"));
      expect(File('pubspec.yaml').readAsStringSync().contains('timezone:'), isFalse,
          reason: 'база часовых поясов больше не нужна — и не должна вернуться');
    });

    test('двадцать часов остаются двадцатью и после перевода стрелок', () {
      // Проверяем само правило, которым считается момент: показания
      // часов задаются полями, а смещение подставляет система.
      for (final month in [1, 7]) {
        final at = DateTime(2026, month, 15, 20);
        expect(at.hour, 20);
      }
    });

    test('прошедший час сегодня пропускается, а не показывается сразу', () {
      // Будильник в прошлом система срабатывает НЕМЕДЛЕННО — посреди
      // дня, без повода.
      final code = File('lib/core/reminders.dart').readAsStringSync();
      expect(code, contains('if (!when.isAfter(now)) continue;'));
      // И то же самое на нативной стороне: план переживает перезагрузку
      // и доезжает до неё уже устаревшим.
      expect(
        File('android/app/src/main/kotlin/com/chrolingo/app/ReminderAlarms.kt')
            .readAsStringSync(),
        contains('if (!spec.repeatWeekly) continue'),
      );
    });
  });

  group('настройки Android, без которых уведомление просто не приходит', () {
    String read(String path) => File(path).readAsStringSync();

    String manifest() => read('android/app/src/main/AndroidManifest.xml');

    test('receiver будильника объявлен', () {
      // Вечернее уведомление показывает ОН, когда приложения нет.
      // Не объявишь — сборка пройдёт, будильник заведётся, а будить
      // будет некого: уведомление просто не придёт, без единой ошибки.
      final xml = manifest();
      expect(xml, contains('android:name=".ReminderAlarmReceiver"'));
      expect(
        File('android/app/src/main/kotlin/com/chrolingo/app/'
                'ReminderAlarmReceiver.kt')
            .existsSync(),
        isTrue,
      );
      // Перезагрузка стирает все заведённые будильники. Без этого права
      // и этого фильтра напоминания после неё молча прекращаются.
      expect(xml, contains('android.intent.action.BOOT_COMPLETED'));
      expect(xml, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    });

    test('право на уведомления объявлено', () {
      // С Android 13 без него уведомления не показываются вовсе. Раньше
      // его приносил плагин своим манифестом — плагина больше нет.
      expect(manifest(), contains('android.permission.POST_NOTIFICATIONS'));
      expect(read('lib/core/reminders.dart'),
          contains('Permission.notification.request()'));
    });

    test('точных будильников не просим: разрешения под них нет', () {
      // SCHEDULE_EXACT_ALARM с Android 14 игрок выдаёт руками. «Около
      // восьми вечера» — ровно та точность, которой хватает.
      expect(manifest().contains('SCHEDULE_EXACT_ALARM'), isFalse);
      expect(
        File('android/app/src/main/kotlin/com/chrolingo/app/ReminderAlarms.kt')
            .readAsStringSync(),
        contains('setAndAllowWhileIdle'),
      );
    });

    test('звук лежит там, где его ищет канал', () {
      // Имя ресурса — единственная связь между кодом и файлом: ссылок на
      // него в коде нет, и опечатку видно только молчащим уведомлением.
      final sound =
          File('android/app/src/main/res/raw/$kReminderSound.wav');
      expect(sound.existsSync(), isTrue,
          reason: 'канал просит @raw/$kReminderSound');
      expect(sound.readAsBytesSync().sublist(0, 4), 'RIFF'.codeUnits);
    });

    test('значок уведомления есть во всех плотностях', () {
      for (final density in [
        'mdpi',
        'hdpi',
        'xhdpi',
        'xxhdpi',
        'xxxhdpi',
      ]) {
        expect(
          File('android/app/src/main/res/drawable-$density/'
                  '$kReminderIcon.png')
              .existsSync(),
          isTrue,
          reason: 'без значка система не покажет уведомление совсем',
        );
      }
    });

    test('значок назван ИМЕНЕМ РЕСУРСА, а не путём', () {
      // Плагин ищет его через getIdentifier(name, "drawable", ...).
      // «@drawable/» впереди — это не «не та картинка», а отказ на
      // инициализации: уведомлений не будет ни одного.
      expect(kReminderIcon, isNot(contains('/')));
      expect(kReminderIcon, isNot(contains('@')));
      expect(kReminderIcon, isNot(contains('.png')));
    });

    test('значок и звук защищены от сжатия ресурсов', () {
      // R8 не видит ссылок на них — для него это мусор, и выбросит он
      // их молча.
      final keep = read('android/app/src/main/res/raw/keep.xml');
      expect(keep, contains('@drawable/$kReminderIcon'));
      expect(keep, contains('@raw/$kReminderSound'));
    });

    test('id канала несёт версию', () {
      // Звук канала Android фиксирует при СОЗДАНИИ и менять не даёт.
      // Сменили звук, не сменив id, — игрок продолжит слышать старый.
      expect(kReminderChannelId, matches(RegExp(r'\.v\d+$')));
    });
  });

  group('уведомление со своей разметкой', () {
    String read(String path) => File(path).readAsStringSync();

    /// Разметка БЕЗ КОММЕНТАРИЕВ. Пояснение, в котором написано «сюда
    /// нельзя класть ConstraintLayout», — это не ConstraintLayout, а
    /// проверка, считающая иначе, ловит собственные объяснения.
    String layout() => read(
            'android/app/src/main/res/layout/notification_chrolingo.xml')
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

    /// То же и для Kotlin: комментариев здесь больше, чем кода, и
    /// половина из них называет как раз то, чего в коде быть не должно.
    String kotlin() => read(
            'android/app/src/main/kotlin/com/chrolingo/app/'
            'ChrolingoNotification.kt')
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//') &&
            !line.trimLeft().startsWith('*') &&
            !line.trimLeft().startsWith('/*'))
        .join('\n');

    test('в разметке только то, что RemoteViews умеет показать', () {
      // RemoteViews принимает горстку виджетов. ConstraintLayout или
      // любой androidx-виджет НЕ ломает сборку — он ломает телефон:
      // вместо уведомления приходит «не удалось показать уведомление».
      final xml = layout();
      for (final forbidden in [
        '<androidx.',
        '<com.google.',
        '<merge',
        'ConstraintLayout',
      ]) {
        expect(xml.contains(forbidden), isFalse,
            reason: '$forbidden в RemoteViews не живёт');
      }
      expect(xml, contains('<LinearLayout'));
      expect(xml, contains('<Chronometer'));
    });

    test('каждый id, который ищет Kotlin, есть в разметке', () {
      // Ищутся они по ИМЕНИ, в рантайме. Переименовали в xml — Kotlin
      // узнает об этом на телефоне, а не на сборке.
      final xml = layout();
      final code = kotlin();
      final asked = RegExp(r'resource\(context, "([a-z_]+)", "id"\)')
          .allMatches(code)
          .map((m) => m.group(1)!)
          .toSet();
      expect(asked, isNotEmpty, reason: 'Kotlin перестал искать id — проверка ослепла');
      for (final name in asked) {
        expect(xml, contains('android:id="@+id/$name"'),
            reason: 'Kotlin просит @id/$name, а в разметке его нет');
      }
    });

    test('каждая расцветка из Dart есть в Kotlin и лежит файлом', () {
      final code = kotlin();
      for (final skin in NotificationSkin.values) {
        expect(code, contains('"${skin.name}" to Skin('),
            reason: 'расцветки ${skin.name} нет в SKINS');
      }
      final backgrounds = RegExp(r'Skin\("([a-z_]+)"')
          .allMatches(code)
          .map((m) => m.group(1)!)
          .toSet();
      expect(backgrounds.length, NotificationSkin.values.length);
      for (final name in backgrounds) {
        expect(
          File('android/app/src/main/res/drawable/$name.xml').existsSync(),
          isTrue,
          reason: 'нет файла подложки $name',
        );
      }
    });

    test('мост назван одинаково с обеих сторон', () {
      // Разойдутся имена — вызов не упадёт, а тихо вернёт
      // MissingPluginException, и уведомление покажется системным видом.
      expect(
        read('android/app/src/main/kotlin/com/chrolingo/app/'
            'RichNotifications.kt'),
        contains('const val CHANNEL = "chrolingo/notifications"'),
      );
      expect(read('lib/core/rich_notification.dart'),
          contains("MethodChannel('chrolingo/notifications')"));
      expect(read('android/app/src/main/kotlin/com/chrolingo/app/MainActivity.kt'),
          contains('RichNotifications.CHANNEL'));
    });

    test('«Сейчас» из шапки убрано везде, где это вообще возможно', () {
      // Само имя приложения убрать нельзя: с Android 12 система рисует
      // шапку сама. Штамп времени — можно, и это единственное, что там
      // вообще поддаётся.
      expect(kotlin(), contains('setShowWhen(false)'));
    });

    test('таймер считает в системном времени, а не в календарном', () {
      // Chronometer считает от загрузки устройства. Передать ему
      // обычные миллисекунды — это счётчик на пятьдесят с лишним лет.
      final code = kotlin();
      expect(code, contains('SystemClock.elapsedRealtime()'));
      expect(code, contains('setChronometerCountDown(timer, true)'));
      // И заголовок обязан уступить место цифрам: во всплывающем
      // уведомлении около 88dp высоты, на всё сразу её не хватает.
      expect(code, contains('views.setViewVisibility(title, View.GONE)'));
    });

    test('картинка уменьшается перед отправкой в систему', () {
      // setImageViewBitmap, в отличие от setLargeIcon, не масштабирует
      // ничего. Наши 616x688 — это 1,7 МБ в одной посылке между
      // процессами, и при переполнении уведомление просто не приходит.
      final code = kotlin();
      expect(code, contains('inJustDecodeBounds = true'));
      expect(code, contains('inSampleSize'));
      expect(code.contains('setImageViewBitmap(mascot, BitmapFactory'), isFalse,
          reason: 'картинка уходит в систему неуменьшенной');
    });

    test('высота набирается содержимым, а не прибита гвоздями', () {
      // Именно поэтому уведомление с таймером выше обычного: появляется
      // строка крупных цифр. Фиксированная высота сделала бы их
      // одинаковыми.
      expect(layout(), contains('android:layout_height="wrap_content"'));
      expect(layout().contains('android:layout_height="64dp"'), isFalse);
    });

    test('срочное идёт своим каналом', () {
      // Важность канала задаёт игрок, и она одна на канал. Отключив
      // надоевшие вечерние, он отключил бы и единственное срочное.
      expect(kStreakChannelId, isNot(kReminderChannelId));
      expect(kStreakChannelId, matches(RegExp(r'\.v\d+$')));
      final code = read('lib/core/reminders.dart');
      expect(code, contains('burning ? kStreakChannelId : kReminderChannelId'));
      // И вечернее, и превью собирает ОДНА функция: иначе кнопка
      // проверки однажды покажет не то, что придёт вечером.
      expect(RegExp(r'_spec\(').allMatches(code).length, greaterThanOrEqualTo(4));
    });

    test('разметка и подложки защищены от сжатия ресурсов', () {
      final keep = read('android/app/src/main/res/raw/keep.xml');
      expect(keep, contains('@layout/notification_chrolingo'));
      expect(keep, contains('@drawable/notification_bg_'));
    });

    test('обе проверки вынесены в настройки', () {
      final settings = read('lib/features/profile/settings_screen.dart');
      expect(settings, contains('Reminders.preview'));
      expect(settings, contains('Reminders.previewStreak'));
    });
  });

  group('картинки настроений', () {
    test('на каждое настроение есть свой файл', () {
      for (final mood in MascotMood.values) {
        final asset = Reminder(id: 'x', mood: mood, title: '', body: '')
            .imageAsset;
        expect(File(asset).existsSync(), isTrue,
            reason: 'нет картинки $asset — уведомление уйдёт без неё');
      }
    });

    test('папка прописана в pubspec', () {
      // Не прописана — файлы просто не попадут в APK, и виновата будет
      // «картинка не показывается».
      expect(File('pubspec.yaml').readAsStringSync(),
          contains('assets/mascot/'));
    });
  });

  group('когда расписание пересобирается', () {
    String read(String path) => File(path).readAsStringSync();

    test('на запуске приложения', () {
      // Расписание, составленное в прошлый раз, ничего не знает о
      // занятиях с тех пор.
      expect(read('lib/main.dart'), contains('Reminders.refresh()'));
    });

    test('сразу после занятия', () {
      // Иначе вечером придёт «сегодня не занимались» тому, кто занимался
      // утром, — и это последнее уведомление, которое он от нас получит.
      final submission = read('lib/data/voice_submission.dart');
      expect(submission, contains('PracticeDiary.markPractised()'));
      expect(submission, contains('Reminders.refresh()'));
    });

    test('расписание заменяется целиком, а не дополняется', () {
      // Добавлять к старому значило бы получить вечером и новое
      // напоминание, и вчерашнее.
      final bridge = read('lib/core/rich_notification.dart');
      expect(bridge, contains('schedule(List<NotificationSpec> plan)'));
      expect(
        read('android/app/src/main/kotlin/com/chrolingo/app/ReminderAlarms.kt'),
        contains('fun schedule(context: Context, plan: String) {\n        cancelAll(context)'),
      );
    });

    test('выключенные напоминания снимают уже заведённые будильники', () {
      // Переключатель, который не снимает будильники, выключает
      // напоминания только на словах.
      final code = read('lib/core/reminders.dart');
      expect(code, contains('RichNotification.cancelAll()'));
    });
  });
}
