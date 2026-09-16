import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/core/local_timezone.dart';
import 'package:language_battle/core/reminders.dart';
import 'package:language_battle/data/practice_diary.dart';
import 'package:language_battle/data/reminder_templates.dart';
import 'package:timezone/timezone.dart' as tz;

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

    test('повторяется раз в неделю, а не раз в день', () {
      final code = File('lib/core/reminders.dart').readAsStringSync();
      expect(code, contains('DateTimeComponents.dayOfWeekAndTime'));
      expect(code, contains('longSilenceReminder()'));
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

  group('часовой пояс без плагина', () {
    // Смещение телефона подставляем сами — иначе тест проверял бы пояс
    // машины, на которой его запустили.
    ZoneOffsetProbe fixed(Duration offset) => (_) => offset;

    ZoneOffsetProbe northernDst(Duration winter, Duration summer) =>
        (DateTime m) => m.month >= 4 && m.month <= 10 ? summer : winter;

    test('пояс без перевода стрелок узнаётся по смещению', () {
      final loc = resolveLocalLocation(
        now: DateTime.utc(2026, 2, 1, 12),
        offsetAt: fixed(const Duration(hours: 3)),
        abbreviation: 'MSK',
      );
      for (final month in [1, 4, 7, 10]) {
        expect(
          loc.timeZone(DateTime.utc(2026, month, 15).millisecondsSinceEpoch)
              .offset,
          const Duration(hours: 3),
        );
      }
    });

    test('пояс с переводом стрелок узнаётся по поведению, а не по имени', () {
      final loc = resolveLocalLocation(
        now: DateTime.utc(2026, 1, 15, 12),
        offsetAt: northernDst(const Duration(hours: 1), const Duration(hours: 2)),
        abbreviation: 'CET',
      );
      expect(
        loc.timeZone(DateTime.utc(2026, 1, 15).millisecondsSinceEpoch).offset,
        const Duration(hours: 1),
      );
      expect(
        loc.timeZone(DateTime.utc(2026, 7, 15).millisecondsSinceEpoch).offset,
        const Duration(hours: 2),
      );
    });

    test('один и тот же телефон получает один и тот же пояс', () {
      // Порядок в хэш-таблице зон не обязан повторяться от запуска к
      // запуску, а «первая подошедшая» обязана.
      String resolve() => resolveLocalLocation(
            now: DateTime.utc(2026, 3, 1),
            offsetAt: fixed(const Duration(hours: 5, minutes: 30)),
            abbreviation: 'IST',
          ).name;
      expect(resolve(), resolve());
    });

    test('пояса, которого нет в базе, хватает своего смещения', () {
      final loc = resolveLocalLocation(
        now: DateTime.utc(2026, 3, 1),
        offsetAt: fixed(const Duration(hours: 5, minutes: 13)),
        abbreviation: 'нет такого',
      );
      expect(
        loc.timeZone(DateTime.utc(2026, 3, 1).millisecondsSinceEpoch).offset,
        const Duration(hours: 5, minutes: 13),
      );
      expect(loc.name, 'UTC+05:13');
    });

    test('смещение к западу от Гринвича подписывается минусом', () {
      expect(fixedOffsetLocation(const Duration(hours: -3, minutes: -30)).name,
          'UTC-03:30');
    });

    test('назначаем показания часов, а не момент времени', () {
      // ЭТО РАЗНЫЕ ВЕЩИ, И ПУТАНИЦА МЕЖДУ НИМИ СТОИТ ЧАСА. TZDateTime.from
      // переводит МОМЕНТ в другую зону — двадцать часов станут двадцатью
      // одним, если смещения разойдутся. TZDateTime(...) строит показания
      // часов прямо в зоне игрока, и двадцать остаются двадцатью.
      ensureTimeZoneData();
      final berlin = tz.getLocation('Europe/Berlin');
      final winter = tz.TZDateTime(berlin, 2026, 1, 15, 20);
      final summer = tz.TZDateTime(berlin, 2026, 7, 15, 20);
      expect(winter.hour, 20);
      expect(summer.hour, 20);
      // И при этом это разные моменты по UTC — перевод стрелок учтён.
      expect(winter.toUtc().hour, 19);
      expect(summer.toUtc().hour, 18);

      // Тот же способ обязан остаться и в коде: сравнение читает
      // команду, а не комментарий рядом с ней.
      final code = File('lib/core/reminders.dart').readAsStringSync();
      expect(code, contains('tz.TZDateTime(\n        tz.local,'));
      expect(code.contains('tz.TZDateTime.from('), isFalse);
    });
  });

  group('настройки Android, без которых уведомление просто не приходит', () {
    String read(String path) => File(path).readAsStringSync();

    String manifest() => read('android/app/src/main/AndroidManifest.xml');

    test('оба receiver\'а объявлены', () {
      // Лежат они внутри плагина, но объявить обязано приложение. Не
      // объявишь — сборка пройдёт, плагин отработает, уведомление не
      // придёт: система не знает, кого будить.
      final xml = manifest();
      expect(
        xml,
        contains('com.dexterous.flutterlocalnotifications'
            '.ScheduledNotificationReceiver'),
      );
      expect(
        xml,
        contains('com.dexterous.flutterlocalnotifications'
            '.ScheduledNotificationBootReceiver'),
      );
      expect(xml, contains('android.intent.action.BOOT_COMPLETED'));
      expect(xml,
          contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    });

    test('desugaring включён и библиотека подключена', () {
      // Без него flutter_local_notifications не собирается вовсе, а
      // сообщение об этом приходит из чужих классов.
      final gradle = read('android/app/build.gradle.kts');
      expect(gradle, contains('isCoreLibraryDesugaringEnabled = true'));
      expect(
        gradle,
        contains('coreLibraryDesugaring("com.android.tools:desugar_jdk_libs'),
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

    test('настройки iOS заданы, хотя собираем APK', () {
      // Без них initialize БРОСАЕТ на iOS, и приложение падает на
      // запуске — не «уведомления не работают», а «не открывается».
      expect(read('lib/core/reminders.dart'),
          contains('DarwinInitializationSettings('));
    });

    test('id канала несёт версию', () {
      // Звук канала Android фиксирует при СОЗДАНИИ и менять не даёт.
      // Сменили звук, не сменив id, — игрок продолжит слышать старый.
      expect(kReminderChannelId, matches(RegExp(r'\.v\d+$')));
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

    test('точное время не просится: разрешения под него нет', () {
      // SCHEDULE_EXACT_ALARM с Android 14 спрашивают у игрока отдельно.
      // «Около восьми вечера» — ровно та точность, которой хватает.
      final code = read('lib/core/reminders.dart');
      expect(code, contains('AndroidScheduleMode.inexactAllowWhileIdle'));
      expect(
        read('android/app/src/main/AndroidManifest.xml')
            .contains('SCHEDULE_EXACT_ALARM'),
        isFalse,
      );
    });
  });
}
