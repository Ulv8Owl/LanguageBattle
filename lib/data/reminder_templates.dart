/// Из чего складывается напоминание: настроение персонажа и текст с цифрами.
///
/// ═══ ЧТО ИМЕННО МЫ ПОВТОРЯЕМ ЗА DUOLINGO ═══
///
/// Их уведомление — НЕ КАРТИНКА, НАРИСОВАННАЯ НА ЛЕТУ. Это видно на их же
/// уведомлениях: заголовок обрезается системным многоточием, а таймер до
/// полуночи тикает сам — ни того ни другого не бывает у готового
/// изображения. Совпадает другое: набор ЗАРАНЕЕ НАРИСОВАННЫХ картинок, из
/// которого выбирается одна по состоянию игрока и времени суток (так же
/// устроен и их виджет — «серия иллюстраций настроения Duo в разное время
/// дня, в зависимости от того, занимался ты или нет»), плюс обычный текст,
/// в который подставлены числа.
///
/// Поэтому здесь нет никакой графики. Здесь решается ровно два вопроса:
/// КАКУЮ картинку показать и КАКИЕ слова написать. Картинку по настроению
/// находит слой уведомлений, числа подставляются в текст.
///
/// ═══ ПОЧЕМУ ВЫБОР ЖИВЁТ ОТДЕЛЬНО ОТ УВЕДОМЛЕНИЙ ═══
///
/// Потому что его можно проверить. Отправку уведомления на сборке не
/// проверишь — нужен телефон, разрешение и ожидание; а «игрок не заходил
/// два дня, серия семь, почти полночь — что ему написать» проверяется
/// тестом за миллисекунду. Разделив, мы получаем единственную часть этой
/// затеи, которая вообще поддаётся проверке до живого запуска.
library;

/// Настроение персонажа. Каждому соответствует своя картинка.
///
/// НАБОР ЗАКРЫТЫЙ И НЕБОЛЬШОЙ НАМЕРЕННО: каждое настроение — это рисунок,
/// который кто-то должен нарисовать. Пять состояний покрывают всё, что мы
/// вообще умеем различать по данным; шестое пришлось бы придумывать под
/// несуществующий повод.
enum MascotMood {
  /// Занимался сегодня. Хвалим и уходим.
  cheerful,

  /// День пропущен, но серия ещё цела — зовём вернуться.
  waiting,

  /// Серия сгорит сегодня. Это единственный повод торопить.
  worried,

  /// Серия уже потеряна, игрока нет несколько дней.
  sad,

  /// Энергия накопилась до потолка и простаивает.
  restless,
}

/// Что мы знаем об игроке к моменту напоминания.
class ReminderState {
  /// Сколько дней назад он занимался. 0 — сегодня.
  final int daysSincePractice;

  /// Длина серии на сейчас.
  final int streakDays;

  /// Местный час, 0–23. От него зависит, торопить или звать.
  final int hour;

  /// Энергия и её потолок — накопившийся запас это повод зайти.
  final int energy;
  final int energyMax;

  const ReminderState({
    required this.daysSincePractice,
    required this.streakDays,
    required this.hour,
    required this.energy,
    required this.energyMax,
  });

  bool get practisedToday => daysSincePractice <= 0;

  bool get energyFull => energyMax > 0 && energy >= energyMax;

  /// Вечер: серия сгорит сегодня, и торопить уже пора. Граница стоит
  /// РАНЬШЕ времени напоминания по умолчанию (20:00) — иначе самый
  /// нужный текст не доставался бы никому.
  bool get lateEvening => hour >= 19;

  int get hoursLeftToday => hour >= 24 ? 0 : 24 - hour;
}

/// Готовое напоминание: картинка, заголовок, текст.
class Reminder {
  /// Ключ шаблона. По нему же считается, что мы уже недавно присылали:
  /// одно и то же слово, сказанное третий раз подряд, перестают читать.
  final String id;
  final MascotMood mood;
  final String title;
  final String body;

  const Reminder({
    required this.id,
    required this.mood,
    required this.title,
    required this.body,
  });

  /// Имя файла с картинкой этого настроения. Одно правило на все
  /// настроения — иначе однажды окажется, что для одного из них картинку
  /// назвали иначе, и уведомление уйдёт без неё.
  String get imageAsset => 'assets/mascot/mood_${mood.name}.png';
}

/// Шаблон до подстановки чисел.
class _Template {
  final String id;
  final MascotMood mood;
  final String Function(ReminderState s) title;
  final String Function(ReminderState s) body;

  const _Template(this.id, this.mood, this.title, this.body);
}

String _days(int n) {
  final last = n % 10;
  final tens = n % 100;
  if (tens >= 11 && tens <= 14) return 'дней';
  if (last == 1) return 'день';
  if (last >= 2 && last <= 4) return 'дня';
  return 'дней';
}

String _hours(int n) {
  final last = n % 10;
  final tens = n % 100;
  if (tens >= 11 && tens <= 14) return 'часов';
  if (last == 1) return 'час';
  if (last >= 2 && last <= 4) return 'часа';
  return 'часов';
}

/// ВСЕ ТЕКСТЫ ЛЕЖАТ ЗДЕСЬ, А НЕ РАЗБРОСАНЫ ПО КОДУ. Их правят чаще любого
/// другого куска этой затеи: голос приложения подбирают наощупь, десятком
/// попыток. Собранные в одном месте, они правятся без единой мысли о том,
/// как устроена отправка.
const List<_Template> _burning = [
  _Template(
    'burning.hours',
    MascotMood.worried,
    _titleBurning,
    _bodyBurningHours,
  ),
  _Template(
    'burning.streak',
    MascotMood.worried,
    _titleBurning,
    _bodyBurningStreak,
  ),
];

String _titleBurning(ReminderState s) => 'Серия ${s.streakDays} сгорит сегодня';
String _bodyBurningHours(ReminderState s) =>
    'Осталось ${s.hoursLeftToday} ${_hours(s.hoursLeftToday)}. Один бой — и она цела.';
String _bodyBurningStreak(ReminderState s) =>
    '${s.streakDays} ${_days(s.streakDays)} подряд — и всё это до полуночи.';

const List<_Template> _waiting = [
  _Template('waiting.short', MascotMood.waiting, _titleWaiting, _bodyWaitingShort),
  _Template('waiting.streak', MascotMood.waiting, _titleWaiting, _bodyWaitingStreak),
];

String _titleWaiting(ReminderState s) => 'Сегодня ещё не занимались';
String _bodyWaitingShort(ReminderState s) => 'Один бой занимает пару минут.';
String _bodyWaitingStreak(ReminderState s) => s.streakDays > 0
    ? 'Серия ${s.streakDays} ${_days(s.streakDays)} ждёт продолжения.'
    : 'Самое время начать серию.';

const List<_Template> _lost = [
  _Template('lost.days', MascotMood.sad, _titleLost, _bodyLostDays),
  _Template('lost.back', MascotMood.sad, _titleLost, _bodyLostBack),
];

String _titleLost(ReminderState s) =>
    'Вас не было ${s.daysSincePractice} ${_days(s.daysSincePractice)}';
String _bodyLostDays(ReminderState s) => 'Серия обнулилась. Новая начинается с одного боя.';
String _bodyLostBack(ReminderState s) => 'Язык забывается быстрее, чем кажется. Вернёмся?';

const List<_Template> _restless = [
  _Template('restless.full', MascotMood.restless, _titleRestless, _bodyRestless),
];

String _titleRestless(ReminderState s) => 'Энергия полная: ${s.energy}';
String _bodyRestless(ReminderState s) =>
    'Копить дальше некуда — она не растёт выше ${s.energyMax}.';

/// Выбирает напоминание под состояние игрока.
///
/// NULL — ЭТО ОТВЕТ, А НЕ ОШИБКА. Занимался сегодня — писать не о чем, и
/// уведомление, посланное «на всякий случай», ровно так и воспринимается:
/// приложение, которое пишет без повода, отключают целиком.
///
/// [recentIds] — что присылали в последние дни. Из подходящих шаблонов
/// берётся первый несвежий; если несвежих нет, берётся первый по кругу.
/// Duolingo решает эту же задачу многоруким бандитом по отклику живых
/// игроков; у нас откликов нет и не будет ещё долго, а повторяться нельзя
/// уже сейчас — поэтому простое чередование, а не подделка под обучение.
Reminder? pickReminder(ReminderState state, {List<String> recentIds = const []}) {
  if (state.practisedToday) return null;

  final List<_Template> bucket;
  if (state.daysSincePractice >= 2) {
    bucket = _lost;
  } else if (state.streakDays > 0 && state.lateEvening) {
    bucket = _burning;
  } else {
    // ПОЛНАЯ ЭНЕРГИЯ НЕ ВЫТЕСНЯЕТ ОСТАЛЬНОЕ, А ВСТАЁТ В ОЧЕРЕДЬ. Она
    // восстанавливается по одной за десять секунд, то есть полна почти
    // всегда; сделай её отдельной причиной — и игрок получал бы
    // «энергия полная» каждый вечер и перестал бы читать вовсе.
    bucket = [..._waiting, if (state.energyFull) ..._restless];
  }

  final fresh = bucket.where((t) => !recentIds.contains(t.id));
  // Все примелькались — берём тот, что показывали ДОЛЬШЕ ВСЕГО НАЗАД, а
  // не первый по списку: иначе за неделю вперёд игрок получил бы одну и
  // ту же строчку пять раз подряд.
  final chosen = fresh.isNotEmpty
      ? fresh.first
      : bucket.reduce((a, b) =>
          recentIds.lastIndexOf(a.id) <= recentIds.lastIndexOf(b.id) ? a : b);
  return Reminder(
    id: chosen.id,
    mood: chosen.mood,
    title: chosen.title(state),
    body: chosen.body(state),
  );
}

/// Напоминание для долгого молчания: когда приложение не открывали
/// дольше, чем расписано вперёд.
///
/// БЕЗ ЕДИНОЙ ЦИФРЫ, И ЭТО ГЛАВНОЕ ЕГО СВОЙСТВО. Оно повторяется само,
/// неделю за неделей, и никто его больше не пересобирает: приложение не
/// открывают — значит, некому. Любое число внутри протухнет в первую же
/// неделю и будет врать все остальные.
Reminder longSilenceReminder() => const Reminder(
      id: 'faded.weekly',
      mood: MascotMood.sad,
      title: 'Язык ждёт',
      body: 'Он забывается быстрее, чем кажется. Один бой — и вернулись.',
    );

/// Настроение для картинки, когда напоминания нет: игрок открыл приложение
/// и заслужил довольного персонажа.
MascotMood moodForToday(ReminderState state) =>
    state.practisedToday ? MascotMood.cheerful : pickReminder(state)!.mood;

/// Каким станет состояние через [daysAhead] дней, если игрок так и не
/// зайдёт, и каким будет час в момент напоминания.
///
/// НУЖНО ПОТОМУ, ЧТО УВЕДОМЛЕНИЯ НАЗНАЧАЮТСЯ ЗАРАНЕЕ — на неделю вперёд,
/// пока приложение открыто. Послезавтрашнее «серия сгорит сегодня»
/// приходит послезавтра, а сочиняется сейчас, и состояние для него нужно
/// послезавтрашнее, а не сегодняшнее.
ReminderState projectState(ReminderState from, int daysAhead, int hour) {
  final since = from.daysSincePractice + daysAhead;
  return ReminderState(
    daysSincePractice: since,
    // Серия догорает в первую же пропущенную полночь. Через день без
    // занятий её уже нет, и обещать её сохранность — врать.
    streakDays: since <= 1 ? from.streakDays : 0,
    hour: hour,
    energy: from.energy,
    energyMax: from.energyMax,
  );
}
