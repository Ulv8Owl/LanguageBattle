/// Часовой пояс телефона — своими силами, без ещё одного плагина.
///
/// ═══ ЗАЧЕМ ЭТО ВООБЩЕ НУЖНО ═══
///
/// Уведомление «занимались бы вечером» назначается на 20:00 ПО МЕСТНОМУ
/// времени, а планировщик Android принимает момент, а не «20:00». Между
/// одним и другим стоит часовой пояс, и Dart его не называет: он знает
/// смещение (`timeZoneOffset`) и сокращение («MSK»), но не имя зоны
/// («Europe/Moscow»), а перевод стрелок расписан именно по именам.
///
/// ═══ ПОЧЕМУ НЕ ПЛАГИН ═══
///
/// Обычный ответ — flutter_timezone, он спрашивает имя у системы. Но это
/// ещё один Android-плагин со своим Kotlin: у него в `android/build.gradle`
/// лежит `classpath kotlin-gradle-plugin:1.7.10`, а у нас в сборке Kotlin
/// 2.4.0 и AGP 9.1.0. Чем это кончится, видно только живой сборкой — а
/// живой сборки у нас в облаке нет (Android SDK не ставится). Ставка «одна
/// строка в pubspec» против «сломанная сборка, которую видно только с
/// телефона» уже проигрывалась дважды на file_picker.
///
/// ═══ ЧТО ДЕЛАЕМ ВМЕСТО ═══
///
/// Зону УЗНАЮТ ПО ПОВЕДЕНИЮ. Смещение спрашивается у самого телефона в
/// четырёх точках года — этого хватает, чтобы отличить зону с переводом
/// стрелок от такой же без него и отличить северное полушарие от южного.
/// Совпала зона по всем четырём — она нам и годится: дальше нас интересует
/// не её название, а ровно то, что мы проверили, — когда у неё сколько.
library;

import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;


/// Смещение телефона в указанный момент. Отдельным типом — чтобы в тестах
/// подставлять любой пояс, а не тот, в котором запущен прогон.
typedef ZoneOffsetProbe = Duration Function(DateTime utcMoment);

/// Сколько точек года опрашиваем и через сколько дней.
const List<int> _probeDays = [0, 91, 182, 273];

bool _dataReady = false;

/// Поднять базу зон. Вызывать до [resolveLocalLocation]; повторные вызовы
/// бесплатны.
void ensureTimeZoneData() {
  if (_dataReady) return;
  tzdata.initializeTimeZones();
  _dataReady = true;
}

/// Зона, которая ведёт себя так же, как телефон.
///
/// [offsetAt] — чем спрашивать смещение (по умолчанию — сам телефон),
/// [abbreviation] — сокращение зоны телефона: им разрешается ничья между
/// одинаково подходящими зонами.
tz.Location resolveLocalLocation({
  DateTime? now,
  ZoneOffsetProbe? offsetAt,
  String? abbreviation,
}) {
  ensureTimeZoneData();
  final at = now?.toUtc() ?? DateTime.now().toUtc();
  final probe = offsetAt ?? (DateTime m) => m.toLocal().timeZoneOffset;
  final moments = [
    for (final days in _probeDays) at.add(Duration(days: days)),
  ];
  final wanted = [for (final m in moments) probe(m)];
  final name = abbreviation ?? DateTime.now().timeZoneName;

  tz.Location? fallback;
  // Имена перебираем по порядку: иначе «подошла первая» зависело бы от
  // порядка в хэш-таблице и одно и то же устройство получало бы разные
  // зоны в разных запусках.
  final names = tz.timeZoneDatabase.locations.keys.toList()..sort();
  for (final key in names) {
    final location = tz.timeZoneDatabase.locations[key]!;
    var fits = true;
    for (var i = 0; i < moments.length; i++) {
      if (location.timeZone(moments[i].millisecondsSinceEpoch).offset !=
          wanted[i]) {
        fits = false;
        break;
      }
    }
    if (!fits) continue;
    // Сокращение — тай-брейк, а не условие: у половины зон мира оно
    // выглядит как «+03», и требовать совпадения значило бы отвергать
    // правильные зоны из-за оформления.
    if (location.timeZone(at.millisecondsSinceEpoch).abbreviation == name) {
      return location;
    }
    fallback ??= location;
  }

  return fallback ?? fixedOffsetLocation(wanted.first);
}

/// Зона без истории: одно смещение навсегда.
///
/// Нужна там, где база нам не помогла, — например у пояса, которого в базе
/// нет вовсе. Перевод стрелок такая зона не переживёт: ближайшее
/// уведомление после перевода придёт на час мимо, а следующий запуск
/// приложения всё поправит. Это худший из возможных исходов здесь, и он
/// заметно лучше, чем уведомление в четыре утра.
tz.Location fixedOffsetLocation(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final total = offset.abs();
  final label = 'UTC$sign${total.inHours.toString().padLeft(2, '0')}:'
      '${(total.inMinutes % 60).toString().padLeft(2, '0')}';
  return tz.Location(
    label,
    const [],
    const [],
    [tz.TimeZone(offset, isDst: false, abbreviation: label)],
  );
}
