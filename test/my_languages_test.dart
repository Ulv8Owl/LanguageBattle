import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/data/achievements.dart';

/// ВЕСЬ ПРОГРЕСС ПРИНАДЛЕЖИТ ИЗУЧАЕМОМУ ЯЗЫКУ (миграция 0051).
///
/// Языковых пар больше нет. Раньше рейтинг делился по парам (ru→en и
/// es→en — разные), а монеты и опыт лежали одной кучей на аккаунт: две
/// несовместимые системы учёта одного игрока. Теперь ключ один — язык,
/// который игрок учит, и к нему привязаны рейтинг, лига, монеты, опыт и
/// достижения.
///
/// Тесты читают сами файлы: инвариант живёт в SQL и в экранах, и проверять
/// его надо там, где он записан.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String progressSql() => read('supabase/migrations/0051_progress_per_learned_language.sql');

  group('язык — единственный ключ прогресса', () {
    test('ключом строки стал изучаемый язык, а не пара', () {
      final sql = progressSql();
      // Ключ пары (user_id, role, language_code, native_for) позволял
      // завести две строки на один изучаемый язык — с разными рейтингами.
      expect(sql, contains('drop index if exists user_languages_pair_key'));
      expect(sql, contains('on user_languages (user_id, role, language_code)'));
    });

    test('монеты и опыт переехали к языку, а старые хранилища удалены', () {
      final sql = progressSql();
      expect(sql, contains('add column if not exists coins integer not null default 0'));
      expect(sql, contains('add column if not exists xp integer not null default 0'));
      // Оставить старое «на всякий случай» значит завести второе место,
      // где лежит золото, и однажды показать игроку не то.
      expect(sql, contains('alter table currency_wallets drop column if exists soft_currency;'));
      expect(sql, contains('alter table users drop column if exists xp;'));
    });

    test('ни одна живая функция не пишет в удалённые колонки', () {
      // finalize_match и claim_training_reward переписаны здесь же; если
      // бы они остались прежними, БД сломалась бы на первом же матче.
      final sql = progressSql();
      final body = sql.substring(sql.indexOf('create or replace function public.finalize_match'));
      expect(body.contains('currency_wallets set soft_currency'), isFalse);
      expect(body.contains('update users set xp'), isFalse);
      expect(body, contains('perform public.grant_language_reward('));
    });

    test('мёртвые функции наборов слов удалены', () {
      final sql = progressSql();
      for (final fn in [
        'public.purchase_word_pack(integer, integer)',
        'public.list_word_packs()',
        'public.mark_word_learned(integer, integer)',
      ]) {
        expect(sql, contains('drop function if exists $fn'));
      }
      // И в клиенте их каталога тоже нет.
      expect(read('lib/core/word_packs.dart').contains('WordPackCatalog'), isFalse);
    });
  });

  group('выбор языков', () {
    test('одна функция вместо четырёх операций над парами', () {
      final sql = progressSql();
      expect(sql, contains('function public.set_my_languages(p_speaks text, p_learns text)'));
      for (final fn in [
        'public.add_language_pair(text, text)',
        'public.set_active_language_pair(text, text)',
        'public.hide_language_pair(text, text)',
        'public.retarget_language_pair(text, text, text, text)',
      ]) {
        expect(sql, contains('drop function if exists $fn'));
      }
    });

    test('прежний активный гасится ДО вставки нового', () {
      // Активный изучаемый язык ровно один (user_languages_one_active_
      // learning, 0009): вставка второго активного до снятия первого
      // падает на индексе — это ловили на живой базе.
      final sql = progressSql();
      final fn = sql.substring(
        sql.indexOf('create or replace function public.set_my_languages'),
        sql.indexOf('grant execute on function public.set_my_languages'),
      );
      expect(fn.indexOf('set is_active = false'),
          lessThan(fn.indexOf('insert into user_languages')));
    });

    test('выбор переехал из Профиля в Настройки', () {
      // В Профиле он стоял посреди достижений, где его случайно и нажимали.
      expect(File('lib/features/profile/language_pair_screen.dart').existsSync(), isFalse);
      expect(read('lib/core/router.dart').contains('/language-pair'), isFalse);
      final profile = read('lib/features/profile/profile_screen.dart');
      expect(profile.contains('ЯЗЫКОВЫЕ ПАРЫ'), isFalse);
      expect(profile.contains('_addPairChip'), isFalse);
      final settings = read('lib/features/profile/settings_screen.dart');
      expect(settings, contains("Text('ЯЗЫКИ'"));
      expect(settings, contains('setMyLanguages(speaks:'));
    });

    test('регистрация заводит языки той же функцией', () {
      // Групповая вставка строк user_languages роняла регистрацию на
      // одном пропущенном ключе и писала никем не читаемую строку
      // role = 'native'.
      expect(File('lib/data/signup_rows.dart').existsSync(), isFalse);
      expect(read('lib/features/onboarding/onboarding_screen.dart'),
          contains('setMyLanguages(speaks: _nativeLanguage, learns: _targetLanguage)'));
      expect(progressSql(), contains("delete from user_languages where role = 'native';"));
    });
  });

  group('достижения', () {
    test('лестницы в Dart и в SQL совпадают', () {
      // Дублирование вынужденное — Dart и Postgres не делят один файл, —
      // и разойдясь, они показали бы игроку не ту ступень, что выдал
      // сервер.
      final sql = progressSql();
      final fn = sql.substring(
        sql.indexOf('create or replace function public.achievement_tiers_reached'),
        sql.indexOf('grant execute on function public.achievement_tiers_reached'),
      );
      for (final kind in AchievementKind.values) {
        expect(fn, contains("'${kind.slug}'"), reason: kind.slug);
      }
      // Первая ступень каждого вида — то, что показано серой плашкой.
      expect(AchievementKind.unstoppable.firstTier, 5);
      expect(AchievementKind.conqueror.firstTier, 1);
      expect(AchievementKind.auditor.firstTier, 1);
      expect(AchievementKind.scholar.firstTier, 10);
      expect(AchievementKind.social.firstTier, 1);
    });

    test('описание подставляет число вместо n', () {
      for (final kind in AchievementKind.values) {
        final text = kind.describe(7);
        expect(text, contains('7'), reason: kind.slug);
        // Латинской «n» в описании больше не остаётся: иначе подстановка
        // задела бы слово, а не число.
        expect(text.contains('n'), isFalse, reason: kind.slug);
      }
    });

    test('каждое достижение принадлежит языку', () {
      final sql = progressSql();
      expect(sql, contains('primary key (user_id, kind, language_code, tier)'));
      expect(read('lib/data/achievements.dart'), contains(".eq('language_code', languages.learns)"));
    });

    test('«Покоритель» считается по матчам, а не счётчиком', () {
      // Счётчик пришлось бы чинить после каждого сбоя; таблица матчей
      // всегда говорит правду.
      final sql = progressSql();
      expect(sql, contains('create or replace function public.pvp_wins'));
      expect(sql, contains('and not m.is_bot_opponent'));
      // Выдаётся триггером: матч завершают ДВЕ функции (finalize_match и
      // forfeit_match), и копия выдачи в обеих разошлась бы.
      expect(sql, contains('create trigger trg_award_conqueror'));
    });

    test('«Аудитор» проверяет, что запись чужая и от носителя', () {
      final sql = progressSql();
      final fn = sql.substring(
        sql.indexOf('create or replace function public.note_voice_listen'),
        sql.indexOf('grant execute on function public.note_voice_listen'),
      );
      expect(fn, contains('v_rec.user_id = v_uid'));
      expect(fn, contains('v_speaker_native is distinct from v_lang'));
      expect(fn, contains('public.is_match_participant('));
      // Одна строка на запись: переслушав ответ трижды, игрок не
      // прослушал трёх носителей.
      expect(sql, contains('primary key (user_id, recording_id)'));
    });

    test('«Знаток» засчитывает слово раз в жизни', () {
      expect(progressSql(), contains('primary key (user_id, language_code, word)'));
      // Событие — пройденная колода: TrainingSession возвращает карточку
      // в конец, пока игрок не ответил уверенно.
      expect(read('lib/features/flashcards/flashcards_screen.dart'),
          contains('if (session.isDone) _noteLearned();'));
    });

    test('«Социальный» считает написанных, а не написавших', () {
      final sql = progressSql();
      final fn = sql.substring(
        sql.indexOf('create or replace function public.sync_social_achievement'),
        sql.indexOf('grant execute on function public.sync_social_achievement'),
      );
      expect(fn, contains('dm.sender_id = v_uid'));
      expect(fn, contains('count(distinct dm.recipient_id)'));
      expect(read('lib/data/chat.dart'), contains('syncSocialAchievement()'));
    });
  });

  group('подбор соперника', () {
    // Тикет собирается из языков игрока, а не из профильного «родного»:
    // тот больше ни на что не влияет.
    test('в очередь уходят языки активной строки', () {
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
