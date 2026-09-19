/// Серия занятий — «стрик».
///
/// ═══ СЧИТАЕТ ЕЁ СЕРВЕР, И ТОЛЬКО ОН ═══
///
/// Клиент сообщает «сегодня занимался таким-то режимом» и показывает то,
/// что вернул сервер (миграция 0056). Серия, которую игрок продлевает
/// себе сам, — не серия, а настройка. Своей копии счёта здесь нет.
///
/// ═══ ДЕНЬ БЕРЁТСЯ МЕСТНЫЙ ═══
///
/// Полночь у игрока своя: в UTC он уже вчерашний, а на часах у него
/// вечер. Серия, оборванная посреди вечера, — худшее, что эта механика
/// умеет, поэтому дату шлёт телефон. Верить ей целиком нельзя, и сервер
/// зажимает присланное в ±1 сутки — этого хватает на любой часовой пояс
/// и не хватает ни на что другое.
///
/// ═══ СЕРИЯ ПРИНАДЛЕЖИТ ЯЗЫКУ ═══
///
/// Как и весь прогресс (миграция 0051). У Duolingo серия одна на
/// аккаунт, и перейдя на другой язык, игрок несёт её с собой — то есть
/// она перестаёт означать «я занимался ЭТИМ языком».
library;

import '../core/app_locale.dart';
import '../core/supabase_client.dart';

/// Чем игрок закрыл день.
///
/// КОД УЕЗЖАЕТ НА СЕРВЕР, ИМЯ — НЕТ. `code` лежит в practice_days и в
/// user_languages.favourite_mode, поэтому переименование режима на экране
/// его не трогает: сменишь код — и вчерашние дни перестанут совпадать с
/// сегодняшними. Имя же берётся из AppStrings, из того же места, что и
/// список Арены, и переведено на оба языка.
enum PracticeMode {
  battle('battle'),
  solo('solo'),
  listening('listening'),
  training('training');

  final String code;

  const PracticeMode(this.code);

  /// `battle` — это ОБА PvP-режима сразу: в practice_days они приходят
  /// одним кодом, и разделить их задним числом нечем.
  String get title => switch (this) {
        PracticeMode.battle => AppLocale.strings.modeBattle,
        PracticeMode.solo => AppLocale.strings.modeVoice,
        PracticeMode.listening => AppLocale.strings.modeListening,
        PracticeMode.training => AppLocale.strings.modeFlashcards,
      };

  static String titleOf(String code) => PracticeMode.values
      .firstWhere((m) => m.code == code, orElse: () => PracticeMode.battle)
      .title;
}

/// Один день календаря.
class StreakDay {
  final DateTime day;
  final bool done;

  /// practice | freeze | repair. Null у пустого дня.
  ///
  /// РАЗЛИЧАТЬ ОБЯЗАТЕЛЬНО. Заморозка, потраченная молча, читается как
  /// сбой счёта: серия цела, а день пустой.
  final String? source;

  const StreakDay({required this.day, required this.done, this.source});

  bool get byFreeze => source == 'freeze';
  bool get byRepair => source == 'repair';
}

/// Серия другого изучаемого языка.
class LanguageStreak {
  final String language;
  final int current;
  final int best;

  const LanguageStreak({
    required this.language,
    required this.current,
    required this.best,
  });
}

class StreakState {
  final String? language;
  final int current;
  final int best;
  final int totalDays;
  final bool todayDone;

  final int freezes;
  final int freezePrice;
  final int maxFreezes;

  /// Что и когда сгорело. Нужно починке.
  final DateTime? brokenOn;
  final int brokenLen;
  final int repairPrice;
  final bool repairAvailable;

  final int coins;
  final int? nextMilestone;
  final int nextMilestoneReward;
  final List<int> milestones;

  final Map<String, int> modeCounts;
  final List<StreakDay> week;
  final List<LanguageStreak> languages;

  /// Веха, только что взятая этим занятием. 0 — не взята.
  final int milestone;
  final int milestoneReward;

  const StreakState({
    required this.language,
    required this.current,
    required this.best,
    required this.totalDays,
    required this.todayDone,
    required this.freezes,
    required this.freezePrice,
    required this.maxFreezes,
    required this.brokenOn,
    required this.brokenLen,
    required this.repairPrice,
    required this.repairAvailable,
    required this.coins,
    required this.nextMilestone,
    required this.nextMilestoneReward,
    required this.milestones,
    required this.modeCounts,
    required this.week,
    required this.languages,
    this.milestone = 0,
    this.milestoneReward = 0,
  });

  static const empty = StreakState(
    language: null,
    current: 0,
    best: 0,
    totalDays: 0,
    todayDone: false,
    freezes: 0,
    freezePrice: 120,
    maxFreezes: 2,
    brokenOn: null,
    brokenLen: 0,
    repairPrice: 150,
    repairAvailable: false,
    coins: 0,
    nextMilestone: 7,
    nextMilestoneReward: 50,
    milestones: [7, 14, 30, 50, 100, 200, 365],
    modeCounts: {},
    week: [],
    languages: [],
  );

  /// Режим, которым закрыто больше всего занятий. Null — занятий ещё нет.
  ///
  /// СЧИТАЕТСЯ ПО ЗАНЯТИЯМ, А НЕ ПО ДНЯМ: за день можно успеть в три
  /// режима, и «любимым» должен стать тот, в который возвращаются.
  String? get favouriteMode {
    String? best;
    var top = 0;
    modeCounts.forEach((mode, count) {
      if (count > top) {
        top = count;
        best = mode;
      }
    });
    return best;
  }

  /// Сколько осталось до следующей вехи.
  int get toNextMilestone =>
      nextMilestone == null ? 0 : (nextMilestone! - current).clamp(0, 9999);

  factory StreakState.fromJson(Map<String, dynamic> json) {
    DateTime? date(String key) {
      final raw = json[key];
      return raw is String ? DateTime.tryParse(raw) : null;
    }

    int number(String key, [int fallback = 0]) =>
        (json[key] as num?)?.toInt() ?? fallback;

    return StreakState(
      language: json['language'] as String?,
      current: number('current'),
      best: number('best'),
      totalDays: number('total_days'),
      todayDone: json['today_done'] as bool? ?? false,
      freezes: number('freezes'),
      freezePrice: number('freeze_price', 120),
      maxFreezes: number('max_freezes', 2),
      brokenOn: date('broken_on'),
      brokenLen: number('broken_len'),
      repairPrice: number('repair_price', 150),
      repairAvailable: json['repair_available'] as bool? ?? false,
      coins: number('coins'),
      nextMilestone: (json['next_milestone'] as num?)?.toInt(),
      nextMilestoneReward: number('next_milestone_reward'),
      milestones: [
        for (final m in (json['milestones'] as List? ?? const []))
          (m as num).toInt(),
      ],
      modeCounts: {
        for (final entry
            in (json['mode_counts'] as Map? ?? const {}).entries)
          entry.key as String: (entry.value as num).toInt(),
      },
      week: [
        for (final day in (json['week'] as List? ?? const []))
          StreakDay(
            day: DateTime.tryParse('${(day as Map)['day']}') ?? DateTime.now(),
            done: day['done'] as bool? ?? false,
            source: day['source'] as String?,
          ),
      ],
      languages: [
        for (final row in (json['languages'] as List? ?? const []))
          LanguageStreak(
            language: (row as Map)['language'] as String? ?? '',
            current: (row['current'] as num?)?.toInt() ?? 0,
            best: (row['best'] as num?)?.toInt() ?? 0,
          ),
      ],
      milestone: number('milestone'),
      milestoneReward: number('milestone_reward'),
    );
  }
}

class Streaks {
  Streaks._();

  /// Местная дата в том виде, в каком её ждёт сервер.
  static String today([DateTime? now]) {
    final at = now ?? DateTime.now();
    return '${at.year.toString().padLeft(4, '0')}-'
        '${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
  }

  static StreakState _parse(dynamic result) => result is Map
      ? StreakState.fromJson(Map<String, dynamic>.from(result))
      : StreakState.empty;

  static Future<StreakState> fetch() async =>
      _parse(await supabase.rpc('streak_state', params: {'p_local_date': today()}));

  /// Отметить занятие. Зовётся там, где игрок ЗАКОНЧИЛ что-то делать, а
  /// не там, где начал: серия за открытый экран — это не серия.
  static Future<StreakState> record(PracticeMode mode) async =>
      _parse(await supabase.rpc('record_practice_day', params: {
        'p_local_date': today(),
        'p_mode': mode.code,
      }));

  static Future<StreakState> buyFreeze() async =>
      _parse(await supabase.rpc('buy_streak_freeze'));

  static Future<StreakState> repair() async =>
      _parse(await supabase.rpc('repair_streak', params: {'p_local_date': today()}));
}
