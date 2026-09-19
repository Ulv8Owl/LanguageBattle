import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/data/streaks.dart';

/// Серия — это прогресс, а прогресс здесь считает сервер. Поэтому
/// половина проверок читает САМУ МИГРАЦИЮ: правило «клиент не пишет
/// счёт» живёт в SQL, и сломать его можно, не тронув ни строчки Dart.
void main() {
  String sql() =>
      File('supabase/migrations/0056_streaks.sql').readAsStringSync();

  String read(String path) => File(path).readAsStringSync();

  group('счёт принадлежит серверу', () {
    test('отметить день можно только через RPC', () {
      final text = sql();
      expect(text, contains('create or replace function public.record_practice_day'));
      expect(text, contains('security definer'));
      expect(text, contains('grant execute on function public.record_practice_day(date, text) to authenticated'));
    });

    test('писать в календарь клиенту нельзя вовсе', () {
      // День, который игрок закрывает себе сам, ничего не значит.
      final text = sql();
      expect(text, contains('create policy practice_days_select_own'));
      expect(text.contains('for insert'), isFalse,
          reason: 'появилась политика записи — клиент сможет закрыть себе день');
      expect(text, contains('grant select on public.practice_days to authenticated'));
      expect(text.contains('grant insert'), isFalse);
      expect(text.contains('grant update'), isFalse);
    });

    test('серия лежит у ЯЗЫКА, а не у аккаунта', () {
      // Весь прогресс здесь принадлежит изучаемому языку (миграция 0051).
      final text = sql();
      expect(text, contains('alter table public.user_languages'));
      expect(text, contains('streak_current'));
      expect(text.contains('alter table public.users'), isFalse,
          reason: 'серия уехала на аккаунт — сменив язык, игрок унесёт её с собой');
    });

    test('присланной дате верят ровно на сутки', () {
      // Полночь у игрока своя, поэтому день берётся местный. Но часы
      // переводит кто угодно, и присланное зажимается.
      final text = sql();
      expect(text, contains('create or replace function public.clamp_local_date'));
      expect(text, contains("(now() at time zone 'utc')::date - 1"));
      expect(text, contains("(now() at time zone 'utc')::date + 1"));
      // И зовётся оно везде, где дата приходит снаружи.
      expect(RegExp(r'public\.clamp_local_date\(p_local_date\)')
          .allMatches(text).length, greaterThanOrEqualTo(3));
    });
  });

  group('правила серии', () {
    test('второй заход за день серию не удлиняет', () {
      // Иначе «серия» означала бы число заходов, а не число дней.
      expect(sql(), contains('if v_last is not null and v_day <= v_last then'));
    });

    test('серия приводится к сегодняшнему дню и при ЧТЕНИИ', () {
      // Сгорает она от бездействия: считать её только при занятии значит
      // показывать вчерашнее число тому, у кого её уже нет.
      final text = sql();
      final state = text.substring(text.indexOf('function public.streak_state'));
      expect(state, contains('perform public.settle_streak'));
      final record = text.substring(text.indexOf('function public.record_practice_day'));
      expect(record, contains('perform public.settle_streak'));
    });

    test('заморозка гасит пропуск и оставляет след в календаре', () {
      // Потраченная молча, она читается как сбой счёта: серия цела, а
      // день пустой.
      final text = sql();
      expect(text, contains('while v_missed > 0 and v_freezes > 0 loop'));
      expect(text, contains("values (p_user_id, p_language, v_last, 'freeze')"));
    });

    test('заморозок не больше двух, и запас проверяется до списания', () {
      final text = sql();
      expect(text, contains('streak_max_freezes()'));
      final buy = text.substring(text.indexOf('function public.buy_streak_freeze'));
      expect(buy.indexOf('freezes_full'), lessThan(buy.indexOf('coins = coins - v_price')),
          reason: 'монеты списываются раньше проверки запаса');
      expect(buy.indexOf('insufficient_funds'), lessThan(buy.indexOf('coins = coins - v_price')));
    });

    test('починка ограничена окном и помечает дни', () {
      final text = sql();
      expect(text, contains('streak_repair_window()'));
      expect(text, contains('repair_expired'));
      expect(text, contains("values (v_uid, v_lang, v_cursor, 'repair')"));
    });

    test('рекорд не убывает', () {
      // greatest, а не присваивание: иначе сгоревшая серия обнулила бы и
      // рекорд, то есть стёрла бы то, что уже случилось.
      expect(sql(), contains('streak_best = greatest('));
    });
  });

  group('вехи', () {
    test('числа в SQL и в заглушке клиента совпадают', () {
      // Заглушка рисуется до ответа сервера. Разойдутся — и игрок увидит
      // одну лестницу, а получит награды по другой.
      final text = sql();
      final array = RegExp(r'select array\[([\d,\s]+)\]').firstMatch(text)!.group(1)!;
      final fromSql = [
        for (final part in array.split(',')) int.parse(part.trim()),
      ];
      expect(StreakState.empty.milestones, fromSql);
    });

    test('награда растёт вместе с вехой', () {
      final text = sql();
      final rewards = RegExp(r'when (\d+) then (\d+)')
          .allMatches(text)
          .map((m) => (int.parse(m.group(1)!), int.parse(m.group(2)!)))
          .toList();
      expect(rewards.length, StreakState.empty.milestones.length);
      for (var i = 1; i < rewards.length; i++) {
        expect(rewards[i].$2, greaterThan(rewards[i - 1].$2),
            reason: 'награда за ${rewards[i].$1} дней не больше предыдущей');
      }
    });
  });

  group('состояние на клиенте', () {
    StreakState parse(Map<String, dynamic> extra) => StreakState.fromJson({
          'language': 'en',
          'current': 5,
          'best': 12,
          'total_days': 40,
          'today_done': false,
          'freezes': 1,
          'freeze_price': 120,
          'max_freezes': 2,
          'coins': 300,
          'next_milestone': 7,
          'next_milestone_reward': 50,
          'milestones': [7, 14, 30],
          'mode_counts': {'battle': 3, 'listening': 9, 'solo': 4},
          'week': [
            {'day': '2026-09-14', 'done': true, 'source': 'practice'},
            {'day': '2026-09-15', 'done': true, 'source': 'freeze'},
            {'day': '2026-09-16', 'done': false, 'source': null},
          ],
          'languages': [
            {'language': 'en', 'current': 5, 'best': 12},
            {'language': 'es', 'current': 2, 'best': 2},
          ],
          ...extra,
        });

    test('разбирается целиком', () {
      final state = parse(const {});
      expect(state.current, 5);
      expect(state.best, 12);
      expect(state.week.length, 3);
      expect(state.week[1].byFreeze, isTrue);
      expect(state.week[2].done, isFalse);
      expect(state.languages.length, 2);
    });

    test('любимый режим — по занятиям, а не по дням', () {
      // За день можно успеть в три режима, и любимым должен стать тот, в
      // который возвращаются.
      expect(parse(const {}).favouriteMode, 'listening');
      expect(PracticeMode.titleOf('listening'), 'Аудирование');
    });

    test('без занятий любимого режима нет', () {
      expect(parse(const {'mode_counts': <String, dynamic>{}}).favouriteMode, isNull);
    });

    test('до вехи считается вперёд и не уходит в минус', () {
      expect(parse(const {'current': 5, 'next_milestone': 7}).toNextMilestone, 2);
      expect(parse(const {'current': 400, 'next_milestone': null}).toNextMilestone, 0);
    });

    test('местная дата уезжает на сервер в его формате', () {
      expect(Streaks.today(DateTime(2026, 1, 5)), '2026-01-05');
      expect(Streaks.today(DateTime(2026, 12, 31, 23, 59)), '2026-12-31');
    });
  });

  group('где это видно', () {
    test('раздел переехал и переименован', () {
      expect(File('lib/features/streak/streak_screen.dart').existsSync(), isTrue);
      expect(File('lib/features/rewards/rewards_screen.dart').existsSync(), isFalse);
      final shell = read('lib/features/arena/arena_shell.dart');
      expect(shell, contains('StreakScreen()'));
      expect(shell, contains('Icons.local_fire_department'));
      expect(shell.contains('Icons.emoji_events'), isFalse,
          reason: 'кубок «Наград» остался на вкладке');
    });

    test('Battle Pass и трек наград убраны, задания остались', () {
      final screen = read('lib/features/streak/streak_screen.dart');
      // В пояснении они упомянуты нарочно — чтобы не вернули по кругу;
      // проверяем КОД, а не текст комментариев.
      final code = screen
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('///'))
          .join('\n');
      expect(code.contains('BATTLE PASS'), isFalse);
      expect(code.contains('ТРЕК НАГРАД'), isFalse);
      expect(code.contains('battle_pass_progress'), isFalse);
      expect(code, contains('ЕЖЕДНЕВНЫЕ ЗАДАНИЯ'));
    });

    test('Профиль показывает серию и больше не тянет все матчи', () {
      final profile = read('lib/features/profile/profile_screen.dart');
      expect(profile, contains('Streaks.fetch()'));
      expect(profile, contains('Любимый режим'));
      expect(profile, contains('дней подряд'));
      // Две выборки всей истории боёв ради трёх чисел, которых на экране
      // больше нет.
      expect(profile.contains("from('matches')"), isFalse);
      expect(profile.contains("label: 'боёв'"), isFalse);
      expect(profile.contains("label: 'побед'"), isFalse);
    });

    test('занятие отмечается там, где оно закончилось', () {
      final player = read('lib/features/listening/player_screen.dart');
      final finish = player.substring(player.indexOf('void _finish()'));
      expect(finish.substring(0, 700), contains('countAsPractice(PracticeMode.listening)'));
      expect(read('lib/data/voice_submission.dart'),
          contains('countAsPractice(roundId == null'));
      expect(read('lib/features/flashcards/flashcards_screen.dart'),
          contains('countAsPractice(PracticeMode.training)'));
      // Каждый режим из перечисления кто-то обязан отмечать: режим,
      // который не отмечает никто, навсегда останется нелюбимым.
      for (final mode in PracticeMode.values) {
        expect(
          [
            'lib/data/voice_submission.dart',
            'lib/features/listening/player_screen.dart',
            'lib/features/flashcards/flashcards_screen.dart',
          ].any((f) => read(f).contains('PracticeMode.${mode.name}')),
          isTrue,
          reason: 'режим ${mode.name} не отмечается нигде',
        );
      }
    });
  });
}
