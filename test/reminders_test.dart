import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/core/reminders.dart';
import 'package:language_battle/core/native_ui.dart';
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
      expect(stageOf(state(days: 0)), isNull);
    });

    test('дуга настроений повторяет дуолинговскую', () {
      // Тревожится в последний вечер, злится назавтра, обижается на
      // третий, плачет на пятый, перестаёт считать через неделю. Это и
      // есть «система настроений», а не украшение.
      final arc = {
        1: MascotMood.worried,
        2: MascotMood.angry,
        3: MascotMood.sad,
        4: MascotMood.sad,
        5: MascotMood.crying,
        6: MascotMood.crying,
        7: MascotMood.lost,
        30: MascotMood.lost,
      };
      arc.forEach((days, mood) {
        expect(pickReminder(state(days: days))!.mood, mood,
            reason: 'на $days-й день настроение должно быть ${mood.name}');
      });
    });

    test('срок меняется ровно там, где игрок это различает', () {
      expect(stageOf(state(days: 1)), ReminderStage.endOfDay);
      expect(stageOf(state(days: 2)), ReminderStage.secondDay);
      expect(stageOf(state(days: 3)), ReminderStage.thirdDay);
      expect(stageOf(state(days: 4)), ReminderStage.thirdDay);
      expect(stageOf(state(days: 5)), ReminderStage.fifthDay);
      expect(stageOf(state(days: 7)), ReminderStage.lostWeek);
    });

    test('серия догорает — свой срок, своё лицо, свой звук', () {
      final evening = pickReminder(state(days: 1, streak: 7, hour: 20))!;
      expect(evening.stage, ReminderStage.burning);
      expect(evening.mood, MascotMood.worried);
      expect(evening.title, contains('7'));

      // Днём та же серия — повод позвать, а не торопить: до полуночи
      // ещё полдня, и «срочно» в полдень обесценивает «срочно» в девять.
      final noon = pickReminder(state(days: 1, streak: 7, hour: 12))!;
      expect(noon.stage, ReminderStage.endOfDay);
      expect(noon.mood, MascotMood.waiting);
    });

    test('вечером последнего дня — торопим и без серии', () {
      // Терять нечего, но день всё равно заканчивается, и это
      // единственное, что ещё можно успеть.
      final r = pickReminder(state(days: 1, streak: 0, hour: 21))!;
      expect(r.stage, ReminderStage.endOfDay);
      expect(r.mood, MascotMood.worried);
      expect(r.body, isNot(contains('Серия')));
    });

    test('каждому сроку — свой набор текстов', () {
      // Пересечься они не должны: один и тот же текст на втором и на
      // седьмом дне обесценивает оба.
      final seen = <String>{};
      for (final days in [1, 2, 3, 5, 9]) {
        final recent = <String>[];
        for (var i = 0; i < 2; i++) {
          final r = pickReminder(state(days: days), recentIds: recent)!;
          expect(seen.add(r.id), isTrue,
              reason: 'текст ${r.id} повторяется на разных сроках');
          recent.add(r.id);
        }
      }
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
      expect(ids.any((id) => id.startsWith('evening')), isTrue);
    });

    test('неполная энергия про энергию молчит', () {
      final recent = <String>[];
      for (var i = 0; i < 4; i++) {
        final r = pickReminder(state(energy: 3, energyMax: 50),
            recentIds: recent)!;
        expect(r.mood, isNot(MascotMood.restless));
        recent.add(r.id);
      }
    });

    test('примелькавшееся уступает место самому давнему', () {
      // Все тексты уже показывали — берём тот, что показывали раньше
      // всех, а не первый по списку.
      final r = pickReminder(
        state(days: 5),
        recentIds: const ['fifth.crying', 'fifth.doubt', 'fifth.doubt'],
      )!;
      expect(r.id, 'fifth.crying');
    });

    test('дни и часы склоняются по-русски', () {
      String streak(int n) =>
          doneTodayReminder(state(days: 0, streak: n)).title;
      expect(streak(1), contains('1 день'));
      expect(streak(2), contains('2 дня'));
      expect(streak(5), contains('5 дней'));
      expect(streak(11), contains('11 дней'));
      expect(streak(21), contains('21 день'));
      expect(streak(22), contains('22 дня'));

      // Часы — в вечернем тексте про остаток дня.
      String body(int hour) => pickReminder(
            state(days: 1, hour: hour),
            recentIds: const [],
          )!.body;
      expect(body(23), contains('1 час'));
      expect(body(21), contains('3 часа'));
      expect(body(19), contains('5 часов'));
    });
  });

  group('отладка по сроку', () {
    test('подставленное состояние даёт ровно тот срок', () {
      // Иначе кнопка «показать 5 дней» присылала бы третий, и проверка
      // врала бы молча.
      for (final stage in ReminderStage.values) {
        final probe = stateForStage(stage, energyMax: 50);
        expect(stageOf(probe), stage,
            reason: 'для ${stage.name} подставлено ${probe.daysSincePractice} дней');
        expect(pickReminder(probe)!.stage, stage);
      }
    });

    test('обычные сроки — все, кроме сгорающего', () {
      // У сгорающего свой цвет, таймер и отдельная кнопка: мешать его в
      // список «обычных» значит проверять не то, что проверяешь.
      expect(ordinaryStages, isNot(contains(ReminderStage.burning)));
      expect(ordinaryStages.length, ReminderStage.values.length - 1);
      for (final stage in ordinaryStages) {
        expect(stageInfo(stage).label, isNotEmpty);
      }
    });

    test('выбор срока и отправка — в настройках', () {
      final settings =
          File('lib/features/profile/settings_screen.dart').readAsStringSync();
      expect(settings, contains('Срок для проверки'));
      expect(settings, contains('Reminders.preview(_stage)'));
      expect(settings, contains('Reminders.preview(ReminderStage.burning)'));
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
      final code = File('lib/core/native_ui.dart').readAsStringSync();
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

    test('у каждого срока свой звук, и он лежит файлом', () {
      // Имя ресурса — единственная связь между кодом и файлом: ссылок на
      // него в коде нет, и опечатку видно только молчащим уведомлением.
      final sounds = <String>{};
      for (final stage in ReminderStage.values) {
        final name = stageInfo(stage).sound;
        expect(sounds.add(name), isTrue,
            reason: 'срок ${stage.name} звучит так же, как другой');
        final file = File('android/app/src/main/res/raw/$name.wav');
        expect(file.existsSync(), isTrue, reason: 'канал просит @raw/$name');
        expect(file.readAsBytesSync().sublist(0, 4), 'RIFF'.codeUnits);
      }
    });

    test('у каждого срока свой канал', () {
      // Звук Android помнит за КАНАЛОМ и менять у существующего не даёт.
      // Один канал на все сроки означал бы один звук на все сроки.
      final channels = <String>{};
      for (final stage in ReminderStage.values) {
        final info = stageInfo(stage);
        expect(channels.add(info.channel), isTrue,
            reason: 'срок ${stage.name} делит канал с другим');
        expect(info.channel, matches(RegExp(r'\.v\d+$')),
            reason: 'без версии в id звук нельзя будет сменить');
      }
    });

    test('отжившие каналы удаляются, а не копятся', () {
      // Канал живёт в настройках телефона дольше, чем в коде: раз
      // созданный, остаётся там навсегда.
      expect(obsoleteChannels, isNotEmpty);
      for (final stage in ReminderStage.values) {
        expect(obsoleteChannels.contains(stageInfo(stage).channel), isFalse,
            reason: 'живой канал попал в список на удаление');
      }
      expect(read('lib/main.dart'), contains('Reminders.tidyChannels()'));
      expect(
        read('android/app/src/main/kotlin/com/chrolingo/app/'
            'ChrolingoNotification.kt'),
        contains('deleteNotificationChannel'),
      );
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
      expect(keep, contains('@raw/voice_'));
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

    test('каждый id, который ищет Kotlin, есть в ОБЕИХ разметках', () {
      // Ищутся они по ИМЕНИ, в рантайме. Разметки две — большая и
      // свёрнутая, — и Kotlin не знает, какую заполняет. Значит, в
      // обеих должен быть один и тот же набор.
      final code = kotlin();
      final asked = RegExp(r'resource\(context, "([a-z_]+)", "id"\)')
          .allMatches(code)
          .map((m) => m.group(1)!)
          .toSet();
      expect(asked, isNotEmpty, reason: 'Kotlin перестал искать id — проверка ослепла');
      for (final file in [
        'notification_chrolingo',
        'notification_chrolingo_compact',
      ]) {
        final xml = read('android/app/src/main/res/layout/$file.xml');
        for (final name in asked) {
          expect(xml, contains('android:id="@+id/$name"'),
              reason: 'Kotlin просит @id/$name, а в $file его нет');
        }
      }
    });

    test('своего скругления у подложки нет', () {
      // Форму карточке задаёт сама шторка: без setStyle уведомление
      // наше целиком, и она обрезает его так, как принято на этой
      // прошивке. Свои углы поверх её углов — вторые углы внутри чужих.
      for (final name in ['notification_bg_gold', 'notification_bg_ember']) {
        final xml = read('android/app/src/main/res/drawable/$name.xml')
            .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
        expect(xml.contains('<corners'), isFalse,
            reason: '$name скругляет сам себя внутри чужой карточки');
      }
      // У виджета наоборот: там наша подложка — это вся карточка, и
      // скруглять её обязаны мы.
      expect(
        read('android/app/src/main/res/drawable/widget_bg_gold.xml'),
        contains('<corners'),
      );
    });

    test('шапку системы НЕ просим — ни одной строкой', () {
      // setStyle(DecoratedCustomViewStyle()) — это ПРОСЬБА нарисовать
      // шапку с именем приложения и белую рамку вокруг. Именно она
      // однажды и стояла здесь, и именно из-за неё уведомление
      // выглядело вложенным в чужую карточку на телефонах, где система
      // ничего не навязывает.
      final code = kotlin();
      expect(code.contains('DecoratedCustomViewStyle'), isFalse);
      expect(code.contains('.setStyle('), isFalse);
    });

    test('свёрнутый вид отдельный — и только там, где система обрезает', () {
      // На Android 12+ свёрнутому достаётся 48dp: большая разметка там
      // обрезается пополам. На телефонах постарше — 106dp, и там нужна
      // большая.
      final code = kotlin();
      expect(code, contains('Build.VERSION.SDK_INT >= Build.VERSION_CODES.S'));
      expect(code, contains('compact = decorated'));
      expect(code, contains('setCustomHeadsUpContentView(views(context, spec, skin, compact = false))'));
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
        contains('const val CHANNEL = "chrolingo/native"'),
      );
      expect(read('lib/core/native_ui.dart'),
          contains("MethodChannel('chrolingo/native')"));
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

    test('картинка уходит РЕСУРСОМ, а не пикселями', () {
      // setImageViewBitmap отправляет пиксели в системный процесс как
      // есть: 616x688 — это 1,7 МБ в одной посылке, а размер посылки
      // ограничен, и при переполнении уведомление просто не приходит.
      // Ресурс уезжает одним числом.
      final code = kotlin();
      expect(code, contains('setImageViewResource(mascot'));
      expect(code.contains('setImageViewBitmap'), isFalse);
      expect(code.contains('BitmapFactory'), isFalse);
    });

    test('на каждое настроение есть ресурс Android, а не только ассет', () {
      // Ассеты Flutter читать некому: и уведомление, и виджет рисуются,
      // когда приложения нет ни в каком виде.
      for (final mood in MascotMood.values) {
        final name = Reminder(id: 'x', stage: ReminderStage.endOfDay, mood: mood, title: '', body: '')
            .mascotResource;
        expect(
          File('android/app/src/main/res/drawable-nodpi/$name.png')
              .existsSync(),
          isTrue,
          reason: 'нет ресурса $name — картинка не доедет до телефона',
        );
      }
    });

    test('высота набирается содержимым, а не прибита гвоздями', () {
      // Именно поэтому уведомление с таймером выше обычного: появляется
      // строка крупных цифр. Фиксированная высота сделала бы их
      // одинаковыми.
      expect(layout(), contains('android:layout_height="wrap_content"'));
      expect(layout().contains('android:layout_height="64dp"'), isFalse);
    });

    test('канал и звук берёт срок, а не отправка', () {
      final code = read('lib/core/reminders.dart');
      expect(code, contains('channelId: info.channel'));
      expect(code, contains('sound: info.sound'));
      // И вечернее, и превью собирает ОДНА функция: иначе кнопка
      // проверки однажды покажет не то, что придёт вечером.
      expect(RegExp(r'_spec\(').allMatches(code).length, greaterThanOrEqualTo(3));
    });

    test('разметка и подложки защищены от сжатия ресурсов', () {
      final keep = read('android/app/src/main/res/raw/keep.xml');
      expect(keep, contains('@layout/notification_chrolingo'));
      expect(keep, contains('@layout/notification_chrolingo_compact'));
      expect(keep, contains('@drawable/notification_bg_'));
    });

    test('проверка вынесена в настройки', () {
      expect(read('lib/features/profile/settings_screen.dart'),
          contains('Reminders.preview('));
    });
  });

  group('виджет на рабочем столе', () {
    String read(String path) => File(path).readAsStringSync();

    String layout() =>
        read('android/app/src/main/res/layout/widget_chrolingo.xml')
            .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

    String kotlin() => read(
            'android/app/src/main/kotlin/com/chrolingo/app/ChrolingoWidget.kt')
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//') &&
            !line.trimLeft().startsWith('*') &&
            !line.trimLeft().startsWith('/*'))
        .join('\n');

    test('receiver объявлен ОТКРЫТЫМ и с описанием', () {
      // exported="true" обязателен: APPWIDGET_UPDATE присылает система,
      // и закрытый receiver его не получит — виджет никогда не
      // обновится, молча. Без meta-data система вообще не узнает, что
      // это виджет.
      final xml = read('android/app/src/main/AndroidManifest.xml');
      expect(xml, contains('android:name=".ChrolingoWidget"'));
      final block = xml.substring(xml.indexOf('.ChrolingoWidget'));
      expect(block.substring(0, 400), contains('android:exported="true"'));
      expect(xml, contains('android.appwidget.action.APPWIDGET_UPDATE'));
      expect(xml, contains('android:name="android.appwidget.provider"'));
      expect(
        File('android/app/src/main/res/xml/chrolingo_widget_info.xml')
            .existsSync(),
        isTrue,
      );
    });

    test('в разметке только то, что RemoteViews умеет показать', () {
      final xml = layout();
      for (final forbidden in [
        '<androidx.',
        '<com.google.',
        '<merge',
        'ConstraintLayout',
      ]) {
        expect(xml.contains(forbidden), isFalse);
      }
      expect(xml, contains('<Chronometer'));
    });

    test('каждый id, который ищет Kotlin, есть в разметке', () {
      final xml = layout();
      final asked = RegExp(r'id\(context, "([a-z_]+)"\)')
          .allMatches(kotlin())
          .map((m) => m.group(1)!)
          .toSet();
      expect(asked, isNotEmpty);
      for (final name in asked) {
        expect(xml, contains('android:id="@+id/$name"'),
            reason: 'Kotlin просит @id/$name, а в разметке его нет');
      }
    });

    test('каждая подложка виджета лежит файлом', () {
      final backgrounds = RegExp(r'Skin\("([a-z_]+)"')
          .allMatches(kotlin())
          .map((m) => m.group(1)!)
          .toSet();
      expect(backgrounds.length, 3, reason: 'обычная, срочная и «сделано»');
      for (final name in backgrounds) {
        expect(
          File('android/app/src/main/res/drawable/$name.xml').existsSync(),
          isTrue,
          reason: 'нет подложки $name',
        );
      }
    });

    test('расцветки Dart и Kotlin называются одинаково', () {
      // Разойдутся — виджет молча покажет золотую подложку вместо
      // алой: неизвестное имя отваливается на значение по умолчанию.
      final dart = read('lib/core/mascot_widget.dart');
      final code = kotlin();
      for (final skin in ['ok', 'ember', 'gold']) {
        expect(dart, contains("'$skin'"));
        expect(code, contains('"$skin" to Skin('));
      }
    });

    test('виджет обновляется отдельно от напоминаний', () {
      // Он висит на рабочем столе и тогда, когда напоминания выключены.
      expect(read('lib/main.dart'), contains('MascotWidget.refresh()'));
      expect(read('lib/data/practice_session.dart'),
          contains('MascotWidget.refresh()'));
      // И вечером, заодно с напоминанием: к вечеру нарисованное утром
      // уже устарело.
      expect(
        read('android/app/src/main/kotlin/com/chrolingo/app/'
            'ReminderAlarmReceiver.kt'),
        contains('ChrolingoWidget.refresh(context)'),
      );
    });

    test('отсчёт на виджете идёт весь день, а не только вечером', () {
      // Уведомление перебивает, поэтому торопит только поздно. Виджет
      // не перебивает — на него смотрят сами.
      final dart = read('lib/core/mascot_widget.dart');
      expect(dart, contains('state.streakDays > 0 && state.daysSincePractice == 1'));
      expect(dart.contains('lateEvening'), isFalse);
    });

    test('превью — обычная картинка, а не иконка приложения', () {
      // Иконка у нас адаптивная (XML в mipmap-anydpi-v26), и часть
      // лаунчеров рисует её в списке виджетов пустым местом. Пустое
      // место в списке неотличимо от «виджета нет вовсе».
      final info = read('android/app/src/main/res/xml/chrolingo_widget_info.xml');
      expect(info, contains('android:previewImage="@drawable/widget_preview"'));
      expect(info.contains('@mipmap/ic_launcher'), isFalse);
      expect(
        File('android/app/src/main/res/drawable-nodpi/widget_preview.png')
            .existsSync(),
        isTrue,
      );
    });

    test('у виджета есть своё имя в списке', () {
      // Без него в списке стоит имя приложения, и среди десятка чужих
      // виджетов его не найти глазами.
      final xml = read('android/app/src/main/AndroidManifest.xml');
      final block = xml.substring(xml.indexOf('.ChrolingoWidget'));
      expect(block.substring(0, 400), contains('android:label='));
    });

    test('приложение умеет спросить систему и поставить виджет само', () {
      // «Виджета нет в списке» — это два разных случая: система не нашла
      // провайдера или список в лаунчере устарел. Снаружи они
      // одинаковы, а чинятся по-разному, поэтому спрашиваем систему.
      final code = kotlin();
      expect(code, contains('getInstalledProvidersForPackage'));
      expect(code, contains('requestPinAppWidget'));
      // requestPinAppWidget появился в Android 8 — на более старых
      // вызов без проверки это падение, а не отказ.
      expect(code, contains('Build.VERSION_CODES.O'));

      final dart = read('lib/core/mascot_widget.dart');
      expect(dart, contains("invokeMapMethod<String, dynamic>(\n          'widgetDiagnose')"));
      expect(dart, contains("invokeMethod<bool>('widgetPin')"));
      expect(read('lib/features/profile/settings_screen.dart'),
          contains('Виджет на рабочем столе'));
    });

    test('ресурсы виджета защищены от сжатия', () {
      final keep = read('android/app/src/main/res/raw/keep.xml');
      expect(keep, contains('@drawable/mascot_'));
      expect(keep, contains('@drawable/widget_bg_'));
      expect(keep, contains('@layout/widget_chrolingo'));
      expect(keep, contains('@drawable/widget_preview'));
      expect(keep, contains('@xml/chrolingo_widget_info'));
    });
  });

  group('картинки настроений', () {
    test('на каждое настроение есть свой файл', () {
      for (final mood in MascotMood.values) {
        final asset = Reminder(id: 'x', stage: ReminderStage.endOfDay, mood: mood, title: '', body: '')
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
      final session = read('lib/data/practice_session.dart');
      expect(session, contains('PracticeDiary.markPractised()'));
      expect(session, contains('Reminders.refresh()'));
      // И это ОДНА точка на все режимы: три вызова, разложенные по
      // экранам, однажды разойдутся, и разойдутся молча.
      for (final caller in [
        'lib/data/voice_submission.dart',
        'lib/features/listening/player_screen.dart',
      ]) {
        expect(read(caller), contains('countAsPractice('),
            reason: '$caller не отмечает занятие');
      }
    });

    test('расписание заменяется целиком, а не дополняется', () {
      // Добавлять к старому значило бы получить вечером и новое
      // напоминание, и вчерашнее.
      final bridge = read('lib/core/native_ui.dart');
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
