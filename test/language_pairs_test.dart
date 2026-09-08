import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Языковая пара — ДВА ЯЗЫКА И БОЛЬШЕ НИЧЕГО: язык, с которого игрок
/// переводит, и язык, который он изучает. Всё, что мешало парам жить —
/// отдельный реестр «родных языков», потолок в четыре пары, опознание пары
/// по одному изучаемому языку, — выросло из попыток хранить этот же факт
/// где-то ещё. Тесты читают сами файлы: инвариант живёт в SQL и в экранах.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String migration() => read('supabase/migrations/0034_pair_identity.sql');
  String pairsSql() => read('supabase/migrations/0046_pairs_without_registry.sql');

  test('пара не может остаться без родного языка', () {
    final sql = migration();
    // Пара с native_for = null читается как `native_for ?? native_language`
    // и переанкоривается при смене главного родного. Дозаполнение без
    // запрета оставило бы ту же ловушку для новых строк.
    expect(sql, contains('set native_for = u.native_language'));
    expect(sql, contains("check (role <> 'learning' or native_for is not null)"));
  });

  test('ключ уникальности включает родной язык', () {
    final sql = migration();
    // unique (user_id, language_code, role) из 0001 не различал ru-es и
    // en-es: для него это одна строка, и вторую пару завести было нельзя.
    expect(sql, contains('drop constraint if exists user_languages_user_id_language_code_role_key'));
    expect(sql, contains("(user_id, role, language_code, coalesce(native_for, ''))"));
  });

  test('удаление плашки не удаляет пару', () {
    final sql = migration();
    // Игрок просит убрать плашку, а не стереть рейтинг и историю. Второе
    // необратимо, и подменять им первое нельзя.
    expect(sql, contains('hidden_at timestamptz'));
    expect(sql, contains('function public.hide_language_pair'));
    expect(sql, contains('update user_languages set hidden_at = now()'));
    // Ни одного delete из user_languages в этой миграции быть не должно.
    expect(sql.contains('delete from user_languages'), isFalse);
  });

  test('активную пару скрыть нельзя', () {
    // Ровно одна пара обязана быть активной (0009); без неё Арена, бой и
    // Тренировка не знают, на каком языке работать.
    expect(migration(), contains('cannot_hide_active_pair'));
  });

  test('повторное добавление возвращает скрытую пару, а не заводит вторую', () {
    final sql = migration();
    // У скрытой остались рейтинг и история — вернуть их правильнее, чем
    // начать рядом с нуля.
    expect(sql, contains('set hidden_at = null where id = v_hidden'));
    expect(sql, contains('return v_hidden;'));
  });

  test('дубликат считается по паре целиком', () {
    final sql = migration();
    final duplicateCheck = sql.substring(
      sql.indexOf('-- Дубликат теперь считается по паре целиком'),
      sql.indexOf("raise exception 'pair_already_exists'"),
    );
    expect(duplicateCheck, contains('native_for = v_native'));
  });

  test('регистрация записывает родной язык пары', () {
    // Корень ошибки en-en: первая пара каждого аккаунта заводилась без
    // native_for и потому следовала за сменой главного родного.
    expect(read('lib/data/signup_rows.dart'), contains("'native_for': nativeLanguage"));
  });

  group('пары без реестра и без потолка', () {
    test('добавление упирается только в совпадение языков', () {
      final sql = pairsSql();
      // Реестр родных был единственной причиной, по которой часть пар
      // завести не удавалось, а потолок в четыре пары — числом с потолка.
      // Проверяем тело, а не комментарий: объяснение, что именно убрано,
      // в файле остаётся намеренно.
      expect(sql.contains("raise exception 'native_not_registered'"), isFalse);
      expect(sql.contains("raise exception 'pair_limit_reached'"), isFalse);
      // Реестр больше не читается: обращений к таблице в теле нет.
      expect(sql.contains('from user_native_languages'), isFalse);
      expect(sql, contains("raise exception 'target_equals_native'"));
      expect(sql, contains("raise exception 'pair_already_exists'"));
    });

    test('оба языка пары можно поменять, не заводя вторую', () {
      // Игрок, ошибившийся с языками при регистрации, до сих пор не мог
      // это исправить: профиля со списком пар ещё нет, а вторая пара
      // осталась бы с ним навсегда.
      final sql = pairsSql();
      expect(sql, contains('function public.retarget_language_pair'));
      // Рейтинг и уровень относились к прежнему изучаемому языку.
      expect(sql, contains('rating = public.elo_default_rating()'));
      expect(sql, contains('cefr_level = null'));
    });

    test('в приложении реестра родных языков не осталось', () {
      // Он хранил тот же факт третьим местом и был лишь ограничителем.
      expect(File('lib/data/native_languages.dart').existsSync(), isFalse);
      for (final path in [
        'lib/features/profile/settings_screen.dart',
        'lib/features/profile/profile_screen.dart',
        'lib/features/profile/language_pair_screen.dart',
      ]) {
        expect(read(path).contains('NativeLanguages'), isFalse, reason: path);
      }
      // И потолка пар тоже нет.
      expect(read('lib/features/profile/profile_screen.dart').contains('kMaxLanguagePairs'),
          isFalse);
    });

    test('оба языка выбираются свободно', () {
      // Раньше «с какого языка» брали только из реестра, а изучаемый — из
      // остатка: половина сочетаний была недоступна.
      final screen = read('lib/features/profile/language_pair_screen.dart');
      expect(screen, contains('onPickSpeaks'));
      expect(screen, contains('onPickLearns'));
      // Недоступен ровно один вариант — второй язык этой же пары.
      expect(screen, contains('taken: {?other}'));
    });

    test('«плюс» всегда последней строкой', () {
      // Раньше он стоял в конце ряда: у одной пары — справа от неё, у
      // пяти — где-то в середине экрана.
      final screen = read('lib/features/profile/profile_screen.dart');
      expect(screen, contains('_addPairChip(),\n      ],'));
      expect(screen.contains('byNative'), isFalse);
    });

    test('пара адресуется обоими языками', () {
      // ru→es и en→es — разные пары с разным рейтингом.
      final data = read('lib/data/language_pairs.dart');
      expect(data, contains("'p_target_language': learns"));
      expect(data, contains("'p_native_language': speaks"));
      final screen = read('lib/features/profile/profile_screen.dart');
      expect(screen, contains('setActiveLanguagePair(speaks: pair.speaks, learns: pair.learns)'));
      expect(screen, contains('hideLanguagePair(speaks: pair.speaks, learns: pair.learns)'));
    });

    test('скрытые пары не показываются', () {
      expect(read('lib/data/language_pairs.dart'), contains(".isFilter('hidden_at', null)"));
    });
  });

  group('подбор соперника после отказа от реестра', () {
    // Тикет собирается из языков АКТИВНОЙ ПАРЫ, а не из профиля: профильный
    // «родной язык» больше ни на что не влияет.
    test('в очередь уходят языки активной пары', () {
      final screen = read('lib/features/matchmaking/matchmaking_screen.dart');
      expect(screen, contains("'p_native_language': nativeLanguage"));
      expect(screen, contains("'p_target_language': targetLanguage"));
    });

    test('дуэль ищет обратную пару, состязание — общий изучаемый', () {
      final sql = read('supabase/migrations/0041_mm_reason.sql');
      expect(sql, contains('b.target_language = a.target_language'));
      expect(sql, contains('b.target_language = a.native_language'));
      expect(sql, contains('b.native_language = a.target_language'));
    });
  });
}
