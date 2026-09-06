import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Языковая пара — это РОДНОЙ ПЛЮС ИЗУЧАЕМЫЙ. Три поломки выросли из
/// допущения, что пару достаточно назвать одним изучаемым языком, и все
/// три выглядели по-разному: пара en-en после смены родного, «языков
/// больше нет» на непустом списке и отказ завести ru-es рядом с en-es.
/// Тесты читают сами файлы: инвариант живёт в SQL и в двух экранах.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String migration() => read('supabase/migrations/0034_pair_identity.sql');

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

  test('экран добавления не запирает сам себя', () {
    final screen = read('lib/features/profile/language_pair_screen.dart');
    // Пустое состояние считалось по ТЕКУЩЕМУ родному и обрывало форму
    // вместе с выбором родного: игрок с парами en-ru и en-es видел
    // «языков больше нет» и не мог переключиться на русский.
    expect(screen, contains('bool get _anythingToAdd'));
    expect(screen, contains('if (!_anythingToAdd) {'));
    // Занятость считается парами, а не изучаемыми языками.
    expect(screen, contains("usedPairs.contains('\$native-\$l')"));
  });

  test('плашка открывает меню, а не переключает пару сразу', () {
    final screen = read('lib/features/profile/profile_screen.dart');
    // Промах по соседней плашке молча уводил на другой язык, и заметно
    // это становилось уже в бою.
    expect(screen, contains('_openPairMenu(pair, anchor)'));
    expect(screen, contains('Выбрать языковую пару'));
    expect(screen, contains('Удалить языковую пару'));
    // Подсвечена выбранная пара, а не та, по которой попали пальцем.
    expect(screen, contains("active: pair['is_active'] == true"));
  });

  test('переключение и скрытие адресуют пару вместе с родным языком', () {
    final screen = read('lib/features/profile/profile_screen.dart');
    for (final call in ['set_active_language_pair', 'hide_language_pair']) {
      final at = screen.indexOf(call);
      expect(at, greaterThan(-1), reason: call);
      expect(screen.substring(at, at + 200), contains('p_native_language'), reason: call);
    }
  });

  test('скрытые пары не показываются на профиле', () {
    expect(read('lib/features/profile/profile_screen.dart'),
        contains("isFilter('hidden_at', null)"));
  });
}
