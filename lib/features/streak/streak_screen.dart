import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/all_languages.dart';
import '../../core/reminders.dart';
import '../../core/theme.dart';
import '../../data/practice_diary.dart';
import '../../data/streaks.dart';
import '../../widgets/chrolingo_widgets.dart';

/// Серия занятий.
///
/// ═══ ЧТО ЗДЕСЬ БЫЛО РАНЬШЕ ═══
///
/// Battle Pass и трек наград: сезонная шкала 0–10 и две ветки вех,
/// бесплатная и подписочная. Обе показывали прогресс, которого игрок не
/// чувствовал — очко за выигранный матч в игре, где матчей бывает по
/// одному в день. Серия чувствуется каждый вечер, и потому заняла их
/// место целиком.
///
/// ═══ ЧТО ВЗЯТО У DUOLINGO ═══
///
/// Огонь с числом, неделя кружками, заморозка на пропущенный день,
/// починка сгоревшей серии за монеты, вехи с наградами. Всё это там
/// работает, и спорить с этим нечего.
///
/// ═══ ЧЕГО У НИХ НЕТ ═══
///
/// 1. СЕРИЯ ПРИНАДЛЕЖИТ ЯЗЫКУ. У них одна на аккаунт: сменив язык,
///    игрок несёт её с собой, и она перестаёт означать «я занимался ЭТИМ
///    языком». Здесь у каждого языка своя, и все видны списком.
/// 2. ЗАМОРОЗКА ВИДНА В КАЛЕНДАРЕ. Потраченная молча, она читается как
///    сбой счёта: серия цела, а день пустой.
/// 3. «ВАШ ЧАС». Телефон знает, когда игрок обычно занимается, и
///    предлагает окликать его в это же время. Напоминание в чужой час
///    читают хуже любого текста.
class StreakScreen extends StatefulWidget {
  const StreakScreen({super.key});

  @override
  State<StreakScreen> createState() => _StreakScreenState();
}

class _StreakScreenState extends State<StreakScreen> {
  StreakState _streak = StreakState.empty;
  bool _loading = true;
  bool _busy = false;

  int? _usualHour;
  int _reminderHour = kReminderDefaultHour;

  /// Тикает, пока день не закрыт: до полуночи осталось столько-то.
  Timer? _ticker;
  Duration _left = Duration.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final streak = await Streaks.fetch();
      final usual = await PracticeDiary.usualHour();
      final hour = await Reminders.hour();
      // Серия с сервера — то, чем живут и уведомления: иначе Профиль
      // покажет 12, а вечернее напоминание — 5.
      await PracticeDiary.adoptServerStreak(
        current: streak.current,
        lastDay: streak.todayDone ? DateTime.now() : null,
      );
      if (!mounted) return;
      setState(() {
        _streak = streak;
        _usualHour = usual;
        _reminderHour = hour;
        _loading = false;
      });
      _restartTicker();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _restartTicker() {
    _ticker?.cancel();
    if (_streak.todayDone) return;
    void tick() {
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day + 1);
      if (!mounted) return;
      setState(() => _left = midnight.difference(now));
    }

    tick();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  /// Покупка и починка ходят одной дорогой: обе тратят монеты, обе
  /// возвращают новое состояние, и обе обязаны внятно объяснить отказ —
  /// «не получилось» без причины злит сильнее самого отказа.
  Future<void> _spend(Future<StreakState> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final streak = await action();
      if (!mounted) return;
      setState(() {
        _streak = streak;
        _busy = false;
      });
      _restartTicker();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final text = e.toString();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          text.contains('insufficient_funds')
              ? 'Не хватает монет'
              : text.contains('freezes_full')
                  ? 'Больше двух заморозок в запасе не бывает'
                  : text.contains('repair_expired')
                      ? 'Эту серию уже не вернуть — прошло больше недели'
                      : 'Не получилось: $e',
        ),
      ));
    }
  }

  Future<void> _useUsualHour() async {
    final hour = _usualHour;
    if (hour == null) return;
    await Reminders.setHour(hour);
    if (await Reminders.isEnabled()) await Reminders.enable(atHour: hour);
    if (!mounted) return;
    setState(() => _reminderHour = hour);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Напоминание переставлено на ${_hh(hour)}'),
    ));
  }

  static String _hh(int hour) => '${hour.toString().padLeft(2, '0')}:00';

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Icon(Icons.local_fire_department, size: 20, color: AppColors.ember),
              const SizedBox(width: 6),
              Text('Серия',
                  style: AppFonts.ui(fontSize: 16, weight: FontWeight.w800)),
              const Spacer(),
              Text('${_streak.coins} монет',
                  style: AppFonts.mono(fontSize: 10, color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 14),
          _FlamePanel(streak: _streak, left: _left),
          const SizedBox(height: 14),
          _WeekStrip(week: _streak.week),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _Tile(
                  value: '${_streak.best}',
                  label: 'рекорд',
                  color: AppColors.gold,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Tile(value: '${_streak.totalDays}', label: 'дней всего'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Tile(
                  value: '${_streak.freezes}/${_streak.maxFreezes}',
                  label: 'заморозки',
                  color: AppColors.diamond,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _label('ВЕХИ'),
          const SizedBox(height: 8),
          _MilestoneTrack(streak: _streak),
          const SizedBox(height: 18),
          _label('ЗАМОРОЗКА'),
          const SizedBox(height: 8),
          ChPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Держит серию за один пропущенный день и тратится сама. '
                  'В календаре такой день помечен льдинкой — чтобы не '
                  'выглядел пройденным.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.45),
                ),
                const SizedBox(height: 10),
                _Action(
                  label: _streak.freezes >= _streak.maxFreezes
                      ? 'Запас полон'
                      : 'Купить за ${_streak.freezePrice}',
                  onPressed: _busy || _streak.freezes >= _streak.maxFreezes
                      ? null
                      : () => _spend(Streaks.buyFreeze),
                ),
              ],
            ),
          ),
          if (_streak.repairAvailable) ...[
            const SizedBox(height: 18),
            _label('СГОРЕВШАЯ СЕРИЯ'),
            const SizedBox(height: 8),
            ChPanel(
              borderColor: AppColors.ember,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Серия из ${_streak.brokenLen} '
                    '${_plural(_streak.brokenLen, 'дня', 'дней', 'дней')} оборвалась. '
                    'Вернуть её можно в течение недели.',
                    style: const TextStyle(fontSize: 12, height: 1.45),
                  ),
                  const SizedBox(height: 10),
                  _Action(
                    label: 'Вернуть за ${_streak.repairPrice}',
                    onPressed: _busy ? null : () => _spend(Streaks.repair),
                  ),
                ],
              ),
            ),
          ],
          if (_streak.languages.length > 1) ...[
            const SizedBox(height: 18),
            _label('СЕРИЯ У КАЖДОГО ЯЗЫКА СВОЯ'),
            const SizedBox(height: 8),
            ChPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final row in _streak.languages)
                    _LanguageRow(row: row, active: row.language == _streak.language),
                ],
              ),
            ),
          ],
          if (_usualHour != null) ...[
            const SizedBox(height: 18),
            _label('ВАШ ЧАС'),
            const SizedBox(height: 8),
            ChPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Чаще всего вы занимаетесь около ${_hh(_usualHour!)}. '
                    'Напоминание сейчас приходит в ${_hh(_reminderHour)}.',
                    style: const TextStyle(fontSize: 12, height: 1.45),
                  ),
                  if (_usualHour != _reminderHour) ...[
                    const SizedBox(height: 10),
                    _Action(
                      label: 'Напоминать в ${_hh(_usualHour!)}',
                      onPressed: _useUsualHour,
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          _label('ЕЖЕДНЕВНЫЕ ЗАДАНИЯ'),
          const SizedBox(height: 8),
          const ChPanel(
            child: Text(
              'Дневные и недельные квесты (раздел 2.6) в этот заход не входили — '
              'здесь появится их список с прогресс-барами.',
              style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Text(
        text,
        style: AppFonts.mono(
            fontSize: 9, weight: FontWeight.w700, color: AppColors.gold),
      );
}

String _plural(int n, String one, String few, String many) {
  final last = n % 10;
  final tens = n % 100;
  if (tens >= 11 && tens <= 14) return many;
  if (last == 1) return one;
  if (last >= 2 && last <= 4) return few;
  return many;
}

/// Главная плашка: огонь, число и то, что с ним будет дальше.
class _FlamePanel extends StatelessWidget {
  final StreakState streak;
  final Duration left;

  const _FlamePanel({required this.streak, required this.left});

  @override
  Widget build(BuildContext context) {
    final alive = streak.current > 0;
    final color = streak.todayDone
        ? AppColors.ember
        : alive
            ? AppColors.gold
            : AppColors.muted;

    return ChPanel(
      borderColor: color,
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.16), blurRadius: 22)],
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Icon(Icons.local_fire_department, size: 56, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${streak.current}',
                  style: AppFonts.mono(
                      fontSize: 34, weight: FontWeight.w700, color: color),
                ),
                Text(
                  alive
                      ? '${_plural(streak.current, 'день', 'дня', 'дней')} подряд'
                      : 'серии пока нет',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
                const SizedBox(height: 8),
                // СЧЁТЧИК ТОЛЬКО ПОКА ДЕНЬ НЕ ЗАКРЫТ. Тикающий над
                // закрытым днём он торопил бы того, кто уже всё сделал.
                if (streak.todayDone)
                  Text('Сегодня закрыт',
                      style: AppFonts.ui(
                          fontSize: 13,
                          weight: FontWeight.w800,
                          color: AppColors.ok))
                else
                  Text(
                    alive
                        ? 'Сгорит через ${_clock(left)}'
                        : 'До полуночи ${_clock(left)}',
                    style: AppFonts.mono(
                        fontSize: 13, weight: FontWeight.w700, color: color),
                  ),
                if (!streak.todayDone)
                  const Text('Один бой — и день закрыт',
                      style: TextStyle(fontSize: 11, color: AppColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// Неделя кружками. Пустой день — тоже ответ, поэтому показаны все семь.
class _WeekStrip extends StatelessWidget {
  final List<StreakDay> week;

  const _WeekStrip({required this.week});

  static const _letters = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

  @override
  Widget build(BuildContext context) {
    if (week.isEmpty) return const SizedBox.shrink();
    final today = week.last.day;

    return ChPanel(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          for (final day in week)
            Column(
              children: [
                Text(
                  _letters[(day.day.weekday - 1) % 7],
                  style: AppFonts.mono(fontSize: 9, color: AppColors.muted),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: day.done
                        ? (day.byFreeze
                            ? AppColors.diamond
                            : day.byRepair
                                ? AppColors.master
                                : AppColors.ember)
                        : Colors.transparent,
                    border: Border.all(
                      color: _sameDay(day.day, today)
                          ? AppColors.gold
                          : AppColors.line,
                      width: _sameDay(day.day, today) ? 2 : 1,
                    ),
                  ),
                  child: Icon(
                    day.byFreeze
                        ? Icons.ac_unit
                        : day.byRepair
                            ? Icons.build
                            : Icons.local_fire_department,
                    size: 16,
                    color: day.done ? AppColors.navy1 : AppColors.line,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Вехи: взятые, ближайшая и то, что за неё дадут.
class _MilestoneTrack extends StatelessWidget {
  final StreakState streak;

  const _MilestoneTrack({required this.streak});

  @override
  Widget build(BuildContext context) {
    return ChPanel(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (streak.nextMilestone != null)
            Text(
              'До ${streak.nextMilestone} дней — ${streak.toNextMilestone} '
              '${_plural(streak.toNextMilestone, 'день', 'дня', 'дней')}. '
              'Награда ${streak.nextMilestoneReward} монет.',
              style: const TextStyle(fontSize: 12, height: 1.4),
            )
          else
            const Text('Все вехи взяты.',
                style: TextStyle(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final milestone in streak.milestones)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _MilestoneChip(
                      days: milestone,
                      reached: streak.best >= milestone,
                      next: milestone == streak.nextMilestone,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MilestoneChip extends StatelessWidget {
  final int days;
  final bool reached;
  final bool next;

  const _MilestoneChip({
    required this.days,
    required this.reached,
    required this.next,
  });

  @override
  Widget build(BuildContext context) {
    final color = reached
        ? AppColors.gold
        : next
            ? AppColors.cream
            : AppColors.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: next ? AppColors.gold : AppColors.line),
        color: reached ? AppColors.goldSoft : Colors.transparent,
      ),
      child: Column(
        children: [
          Icon(
            reached ? Icons.local_fire_department : Icons.lock_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(height: 3),
          Text('$days',
              style: AppFonts.mono(
                  fontSize: 11, weight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

class _LanguageRow extends StatelessWidget {
  final LanguageStreak row;
  final bool active;

  const _LanguageRow({required this.row, required this.active});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Text(languageFlag(row.language), style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              languageName(row.language),
              style: AppFonts.ui(
                fontSize: 13,
                weight: active ? FontWeight.w800 : FontWeight.w400,
                color: active ? AppColors.cream : AppColors.muted,
              ),
            ),
          ),
          Icon(Icons.local_fire_department,
              size: 14, color: active ? AppColors.ember : AppColors.muted),
          const SizedBox(width: 4),
          Text('${row.current}',
              style: AppFonts.mono(
                  fontSize: 12,
                  weight: FontWeight.w700,
                  color: active ? AppColors.ember : AppColors.muted)),
        ],
      ),
    );
  }
}

/// Кнопка раздела. Отключённая ОСТАЁТСЯ НА МЕСТЕ и подписана причиной
/// («Запас полон»): исчезающая кнопка выглядит как сбой, а не как отказ.
class _Action extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const _Action({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: enabled ? AppColors.gold : AppColors.muted,
          side: BorderSide(color: enabled ? AppColors.gold : AppColors.line),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        child: Text(label,
            style: AppFonts.ui(fontSize: 13, weight: FontWeight.w800)),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _Tile({
    required this.value,
    required this.label,
    this.color = AppColors.cream,
  });

  @override
  Widget build(BuildContext context) {
    return ChPanel(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Column(
        children: [
          Text(value,
              style: AppFonts.mono(
                  fontSize: 15, weight: FontWeight.w700, color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 8, color: AppColors.muted)),
        ],
      ),
    );
  }
}
