/// Из чего складывается напоминание: срок, настроение персонажа и текст.
///
/// ═══ ЧТО ИМЕННО МЫ ПОВТОРЯЕМ ЗА DUOLINGO ═══
///
/// Не картинку, нарисованную на лету, — таких у них нет. Совпадает
/// другое: набор ЗАРАНЕЕ НАРИСОВАННЫХ настроений, из которого выбирается
/// одно по тому, сколько игрока нет. Их сова сначала тревожится («зайди,
/// а то потеряешь»), назавтра злится, а через несколько дней плачет.
/// Ровно эта дуга здесь и описана.
///
/// ═══ СРОК РЕШАЕТ ВСЁ ═══
///
/// [ReminderStage] — единственная развилка в этом файле. От неё зависит
/// и настроение, и слова, и ЗВУК: у каждого срока свой канал Android со
/// своим звуком. Уведомление, звучащее всегда одинаково, перестают
/// слышать на третий день — рука смахивает его раньше, чем глаз прочёл
/// заголовок. Разный звук успевает сказать «это другое» ДО чтения.
///
/// ═══ ПОЧЕМУ ВЫБОР ЖИВЁТ ОТДЕЛЬНО ОТ ОТПРАВКИ ═══
///
/// Потому что его можно проверить. Отправку на сборке не проверишь —
/// нужен телефон, разрешение и ожидание; а «игрока нет пять дней — что
/// ему написать и каким голосом» проверяется тестом за миллисекунду.
library;

/// Настроение персонажа. Каждому соответствует своя картинка.
///
/// КАЖДОЕ — ЭТО РИСУНОК, КОТОРЫЙ КТО-ТО ДОЛЖЕН НАРИСОВАТЬ, поэтому набор
/// закрытый. Первые семь — дуга «не заходил всё дольше»: от спокойного
/// ожидания до отчаяния. Восьмое стоит в стороне и к сроку отношения не
/// имеет.
enum MascotMood {
  /// Занимался сегодня. Хвалим и уходим.
  cheerful,

  /// День идёт, занятия ещё не было. Спокойно зовём.
  waiting,

  /// День кончается. Тревожится и торопит — это он «кричит».
  worried,

  /// День пропущен. Злится.
  angry,

  /// Третий день. Обиделся.
  sad,

  /// Пятый день. Плачет.
  crying,

  /// Неделя и дольше. Перестал считать дни.
  lost,

  /// Энергия накопилась до потолка и простаивает. К сроку не относится.
  restless,
}

/// Сколько игрока нет — и, значит, каким голосом с ним говорить.
///
/// ГРАНИЦЫ ВЫБРАНЫ ПО ТОМУ, ЧТО ИГРОК РАЗЛИЧАЕТ САМ. «Третий день» и
/// «четвёртый» для него одно и то же, а «сегодня» и «вчера» — нет.
enum ReminderStage {
  /// Серия догорает сегодня вечером. Единственный срок с таймером.
  burning,

  /// Сегодня ещё не занимались.
  endOfDay,

  /// Пропущен один день.
  secondDay,

  /// Третий-четвёртый день.
  thirdDay,

  /// Пятый-шестой.
  fifthDay,

  /// Неделя и дольше.
  lostWeek,
}

/// Всё, что срок задаёт помимо текста: настроение, канал, звук.
class ReminderStageInfo {
  /// Как срок называется в отладке — словами игрока, а не кода.
  final String label;

  final MascotMood mood;

  /// Канал Android. СВОЙ У КАЖДОГО СРОКА, потому что звук Android
  /// запоминает при создании канала и менять у существующего не даёт.
  final String channel;

  /// Как канал подписан в системных настройках телефона. Игрок увидит
  /// этот список и сможет отключить сроки по одному — это возможность,
  /// а не побочный эффект.
  final String channelName;

  /// Имя файла в `res/raw` без расширения.
  final String sound;

  /// Сколько дней подставить, чтобы получить этот срок в отладке.
  final int probeDays;

  const ReminderStageInfo({
    required this.label,
    required this.mood,
    required this.channel,
    required this.channelName,
    required this.sound,
    required this.probeDays,
  });
}

const Map<ReminderStage, ReminderStageInfo> _stages = {
  ReminderStage.burning: ReminderStageInfo(
    label: 'Серия сгорает',
    mood: MascotMood.worried,
    channel: 'chrolingo.burning.v1',
    channelName: 'Серия сгорает',
    sound: 'voice_burning',
    probeDays: 1,
  ),
  ReminderStage.endOfDay: ReminderStageInfo(
    label: 'Конец дня',
    mood: MascotMood.worried,
    channel: 'chrolingo.endofday.v1',
    channelName: 'Конец дня',
    sound: 'voice_endofday',
    probeDays: 1,
  ),
  ReminderStage.secondDay: ReminderStageInfo(
    label: '2-й день',
    mood: MascotMood.angry,
    channel: 'chrolingo.second.v1',
    channelName: 'Пропущенный день',
    sound: 'voice_second',
    probeDays: 2,
  ),
  ReminderStage.thirdDay: ReminderStageInfo(
    label: '3-й день',
    mood: MascotMood.sad,
    channel: 'chrolingo.third.v1',
    channelName: 'Несколько дней',
    sound: 'voice_third',
    probeDays: 3,
  ),
  ReminderStage.fifthDay: ReminderStageInfo(
    label: '5 дней',
    mood: MascotMood.crying,
    channel: 'chrolingo.fifth.v1',
    channelName: 'Пять дней',
    sound: 'voice_fifth',
    probeDays: 5,
  ),
  ReminderStage.lostWeek: ReminderStageInfo(
    label: 'Больше недели',
    mood: MascotMood.lost,
    channel: 'chrolingo.week.v1',
    channelName: 'Больше недели',
    sound: 'voice_week',
    probeDays: 9,
  ),
};

ReminderStageInfo stageInfo(ReminderStage stage) => _stages[stage]!;

/// Сроки, которые показывает ОБЫЧНОЕ уведомление. Без [ReminderStage.burning]:
/// у того свой вид, свой цвет и таймер.
const List<ReminderStage> ordinaryStages = [
  ReminderStage.endOfDay,
  ReminderStage.secondDay,
  ReminderStage.thirdDay,
  ReminderStage.fifthDay,
  ReminderStage.lostWeek,
];

/// Каналы, которые когда-то были и больше не нужны.
///
/// УДАЛЯТЬ ОБЯЗАТЕЛЬНО. Канал, созданный однажды, остаётся в настройках
/// телефона навсегда — даже если приложение о нём забыло. Список из
/// восьми каналов, половина которых мертва, выглядит как неряшливость, и
/// отключают в нём обычно всё сразу.
const List<String> obsoleteChannels = [
  'chrolingo.reminders.v1',
  'chrolingo.streak.v1',
];

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

  /// Вечер: день заканчивается, и звать пора уже настойчиво. Граница
  /// стоит РАНЬШЕ времени напоминания по умолчанию (20:00) — иначе самый
  /// нужный текст не доставался бы никому.
  bool get lateEvening => hour >= 19;

  int get hoursLeftToday => hour >= 24 ? 0 : 24 - hour;
}

/// Какой срок у этого состояния. null — писать не о чем.
///
/// NULL — ЭТО ОТВЕТ, А НЕ ОШИБКА. Занимался сегодня — повода нет, и
/// уведомление «на всякий случай» ровно так и воспринимается:
/// приложение, которое пишет без повода, отключают целиком.
ReminderStage? stageOf(ReminderState state) {
  if (state.practisedToday) return null;
  final days = state.daysSincePractice;
  if (days <= 1) {
    // Серия жива до полуночи, и только этот случай стоит таймера.
    return state.streakDays > 0 && state.lateEvening
        ? ReminderStage.burning
        : ReminderStage.endOfDay;
  }
  if (days == 2) return ReminderStage.secondDay;
  if (days <= 4) return ReminderStage.thirdDay;
  if (days <= 6) return ReminderStage.fifthDay;
  return ReminderStage.lostWeek;
}

/// Готовое напоминание: срок, картинка, заголовок, текст.
class Reminder {
  /// Ключ шаблона. По нему же считается, что мы уже недавно присылали:
  /// одно и то же слово, сказанное третий раз подряд, перестают читать.
  final String id;

  /// Срок задаёт канал и звук — см. [stageInfo].
  final ReminderStage stage;

  final MascotMood mood;
  final String title;
  final String body;

  const Reminder({
    required this.id,
    required this.stage,
    required this.mood,
    required this.title,
    required this.body,
  });

  /// Имя файла с картинкой этого настроения. Одно правило на все
  /// настроения — иначе однажды окажется, что для одного из них картинку
  /// назвали иначе, и уведомление уйдёт без неё.
  String get imageAsset => 'assets/mascot/mood_${mood.name}.png';

  /// То же настроение ресурсом Android — для уведомления и виджета.
  /// Их рисуют без приложения, и ассет Flutter там читать нечем.
  String get mascotResource => 'mascot_${mood.name}';
}

/// Шаблон до подстановки чисел.
class _Template {
  final String id;
  final String Function(ReminderState s) title;
  final String Function(ReminderState s) body;

  /// Настроение обычно берётся у срока. Здесь — только если в одном
  /// сроке живут разные лица (день и вечер) или повод вовсе не про срок.
  final MascotMood? mood;

  const _Template(this.id, this.title, this.body, {this.mood});
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

/// ВСЕ ТЕКСТЫ ЛЕЖАТ ЗДЕСЬ, А НЕ РАЗБРОСАНЫ ПО КОДУ. Их правят чаще
/// любого другого куска этой затеи: голос приложения подбирают наощупь,
/// десятком попыток. Собранные в одном месте, они правятся без единой
/// мысли о том, как устроена отправка.

const List<_Template> _burning = [
  _Template('burning.hours', _titleBurning, _bodyBurningHours),
  _Template('burning.streak', _titleBurning, _bodyBurningStreak),
];

String _titleBurning(ReminderState s) => 'Серия ${s.streakDays} сгорит сегодня';
String _bodyBurningHours(ReminderState s) =>
    'Осталось ${s.hoursLeftToday} ${_hours(s.hoursLeftToday)}. Один бой — и она цела.';
String _bodyBurningStreak(ReminderState s) =>
    '${s.streakDays} ${_days(s.streakDays)} подряд — и всё это до полуночи.';

/// Днём — зовём спокойно: до полуночи ещё полдня, и «срочно» в полдень
/// обесценивает «срочно» в девять.
const List<_Template> _dayCalm = [
  _Template('day.short', _titleDay, _bodyDayShort, mood: MascotMood.waiting),
  _Template('day.streak', _titleDay, _bodyDayStreak, mood: MascotMood.waiting),
];

String _titleDay(ReminderState s) => 'Сегодня ещё не занимались';
String _bodyDayShort(ReminderState s) => 'Один бой занимает пару минут.';
String _bodyDayStreak(ReminderState s) => s.streakDays > 0
    ? 'Серия ${s.streakDays} ${_days(s.streakDays)} ждёт продолжения.'
    : 'Самое время начать серию.';

/// Вечером — торопим. Это и есть то, что у Duolingo «кричит».
const List<_Template> _eveningRush = [
  _Template('evening.hours', _titleEvening, _bodyEveningHours),
  _Template('evening.sleep', _titleEvening, _bodyEveningSleep),
];

String _titleEvening(ReminderState s) => 'День заканчивается';
String _bodyEveningHours(ReminderState s) =>
    'Осталось ${s.hoursLeftToday} ${_hours(s.hoursLeftToday)}. Один бой — и день не пустой.';
String _bodyEveningSleep(ReminderState s) =>
    'Chro не ложится спать. Ждёт один бой — дальше только завтра.';

const List<_Template> _secondDay = [
  _Template('second.angry', _titleSecond, _bodySecondAngry),
  _Template('second.habit', _titleSecond, _bodySecondHabit),
];

String _titleSecond(ReminderState s) => 'Вчера — мимо';
String _bodySecondAngry(ReminderState s) =>
    'Chro сердится. Серия обнулилась, новая начинается с одного боя.';
String _bodySecondHabit(ReminderState s) =>
    'Второй пропуск даётся легче первого. Один бой это прекращает.';

const List<_Template> _thirdDay = [
  _Template('third.offended', _titleThird, _bodyThirdOffended),
  _Template('third.forget', _titleThird, _bodyThirdForget),
];

String _titleThird(ReminderState s) =>
    'Вас не было ${s.daysSincePractice} ${_days(s.daysSincePractice)}';
String _bodyThirdOffended(ReminderState s) =>
    'Chro обиделся. Он отходчивый — хватит одного боя.';
String _bodyThirdForget(ReminderState s) =>
    'Язык забывается быстрее, чем кажется. Начать — две минуты.';

const List<_Template> _fifthDay = [
  _Template('fifth.crying', _titleFifth, _bodyFifthCrying),
  _Template('fifth.doubt', _titleFifth, _bodyFifthDoubt),
];

String _titleFifth(ReminderState s) =>
    '${s.daysSincePractice} ${_days(s.daysSincePractice)} тишины';
String _bodyFifthCrying(ReminderState s) =>
    'Chro плачет в углу. Один бой — и перестанет.';
String _bodyFifthDoubt(ReminderState s) =>
    'Chro уже не уверен, что вы вернётесь. Разубедите его.';

const List<_Template> _lostWeek = [
  _Template('week.place', _titleWeek, _bodyWeekPlace),
  _Template('week.count', _titleWeek, _bodyWeekCount),
];

String _titleWeek(ReminderState s) => 'Неделя прошла';
String _bodyWeekPlace(ReminderState s) =>
    'Здесь всё на месте: язык, слова, Chro. Нужен один бой.';
String _bodyWeekCount(ReminderState s) =>
    'Chro перестал считать дни. Начать заново — это один бой.';

const List<_Template> _restless = [
  _Template('restless.full', _titleRestless, _bodyRestless,
      mood: MascotMood.restless),
];

String _titleRestless(ReminderState s) => 'Энергия полная: ${s.energy}';
String _bodyRestless(ReminderState s) =>
    'Копить дальше некуда — она не растёт выше ${s.energyMax}.';

List<_Template> _bucketFor(ReminderState state, ReminderStage stage) {
  switch (stage) {
    case ReminderStage.burning:
      return _burning;
    case ReminderStage.endOfDay:
      return [
        ...(state.lateEvening ? _eveningRush : _dayCalm),
        // ПОЛНАЯ ЭНЕРГИЯ НЕ ВЫТЕСНЯЕТ ОСТАЛЬНОЕ, А ВСТАЁТ В ОЧЕРЕДЬ. Она
        // восстанавливается по одной за десять секунд, то есть полна
        // почти всегда; сделай её отдельной причиной — и игрок получал
        // бы «энергия полная» каждый вечер и перестал бы читать вовсе.
        if (state.energyFull) ..._restless,
      ];
    case ReminderStage.secondDay:
      return _secondDay;
    case ReminderStage.thirdDay:
      return _thirdDay;
    case ReminderStage.fifthDay:
      return _fifthDay;
    case ReminderStage.lostWeek:
      return _lostWeek;
  }
}

/// Выбирает напоминание под состояние игрока.
///
/// [recentIds] — что присылали в последние дни. Из подходящих шаблонов
/// берётся первый несвежий. Duolingo решает эту же задачу многоруким
/// бандитом по отклику живых игроков; у нас откликов нет и не будет ещё
/// долго, а повторяться нельзя уже сейчас — поэтому простое чередование,
/// а не подделка под обучение.
Reminder? pickReminder(ReminderState state, {List<String> recentIds = const []}) {
  final stage = stageOf(state);
  if (stage == null) return null;
  final bucket = _bucketFor(state, stage);

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
    stage: stage,
    mood: chosen.mood ?? stageInfo(stage).mood,
    title: chosen.title(state),
    body: chosen.body(state),
  );
}

/// Что показывать, когда показывать нечего: игрок занимался сегодня.
///
/// УВЕДОМЛЕНИЮ ЭТО НЕ НУЖНО — оно в таком случае просто молчит. А виджет
/// молчать не умеет: он всегда на экране, и пустым быть не может.
Reminder doneTodayReminder(ReminderState s) => Reminder(
      id: 'done.today',
      stage: ReminderStage.endOfDay,
      mood: MascotMood.cheerful,
      title: s.streakDays > 0
          ? 'Серия ${s.streakDays} ${_days(s.streakDays)}'
          : 'Сегодня сделано',
      body: 'На сегодня всё. Возвращайтесь завтра.',
    );

/// Текст срочного вида, где цифры показывает ТАЙМЕР, а не текст.
///
/// «Осталось 4 часа», написанное рядом с тикающим счётчиком, спорит с
/// ним уже через час: счётчик считает, текст — нет. Поэтому здесь про
/// часы не говорится вовсе.
String burningBody(ReminderState s) =>
    'Серия ${s.streakDays} ${_days(s.streakDays)} держится. Один бой — и она цела.';

/// Напоминание для долгого молчания: когда приложение не открывали
/// дольше, чем расписано вперёд.
///
/// БЕЗ ЕДИНОЙ ЦИФРЫ, И ЭТО ГЛАВНОЕ ЕГО СВОЙСТВО. Оно повторяется само,
/// неделю за неделей, и никто его больше не пересобирает: приложение не
/// открывают — значит, некому. Любое число внутри протухнет в первую же
/// неделю и будет врать все остальные.
Reminder longSilenceReminder() => const Reminder(
      id: 'faded.weekly',
      stage: ReminderStage.lostWeek,
      mood: MascotMood.lost,
      title: 'Язык ждёт',
      body: 'Он забывается быстрее, чем кажется. Один бой — и вернулись.',
    );

/// Состояние, дающее ровно этот срок. Нужно отладке: проверяющий
/// выбирает срок, а не подбирает дни, при которых тот получится.
ReminderState stateForStage(ReminderStage stage, {required int energyMax}) {
  final info = stageInfo(stage);
  return ReminderState(
    daysSincePractice: info.probeDays,
    // Серия нужна только сгорающему сроку: у остальных она к этому
    // моменту давно сгорела, и рисовать её значило бы врать.
    streakDays: stage == ReminderStage.burning ? 1 : 0,
    // Вечер: именно в этот час приходят настоящие напоминания.
    hour: 21,
    energy: energyMax,
    energyMax: energyMax,
  );
}

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
