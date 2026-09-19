import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/data/account.dart';

/// Вход и регистрация. Половина правил здесь живёт не в Dart: одно — в
/// правах на функцию Postgres, другое — в тексте Edge Function. Сломать
/// их можно, не тронув ни одного экрана, поэтому проверки читают сами
/// файлы.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String sql() =>
      read('supabase/migrations/0057_guest_accounts.sql');

  group('ник', () {
    test('занимается через RPC, а не записью в строку', () {
      // Клиент, пишущий username напрямую, получает на занятом нике
      // сырую ошибку Postgres про индекс — её нельзя показать игроку.
      final text = sql();
      expect(text, contains('create or replace function public.claim_username'));
      expect(text, contains('security definer'));
      expect(text, contains('grant execute on function public.claim_username(text) to authenticated'));
      expect(text, contains('username_taken'));
    });

    test('уникален без оглядки на регистр', () {
      // «Chrolingo» и «chrolingo» — один ник для человека и два для
      // базы: игрок зарегистрирует второй и будет уверен, что это первый.
      expect(sql(), contains('create unique index if not exists users_username_lower_key'));
      expect(sql(), contains('on public.users (lower(username))'));
    });

    test('у гостя имя есть всегда', () {
      // Пустое место в чужих списках читается как сбой, а не как
      // «человек не представился».
      expect(sql(), contains('function public.ensure_guest_name'));
      expect(read('lib/features/auth/welcome_screen.dart'),
          contains('Account.ensureGuestName()'));
    });
  });

  group('вход по нику не раздаёт почту', () {
    test('resolve_login_email закрыта от игроков', () {
      // Ники видны всем (Арена, друзья, рейтинг). Функция, доступная
      // клиенту, превратила бы список ников в список адресов.
      final text = sql();
      expect(text, contains('revoke all on function public.resolve_login_email(text) from public, anon, authenticated'));
      expect(text, contains('grant execute on function public.resolve_login_email(text) to service_role'));
      expect(
        RegExp(r'grant execute on function public\.resolve_login_email\(text\) to authenticated')
            .hasMatch(text),
        isFalse,
      );
    });

    test('ответ на неверный ник и на неверный пароль одинаков', () {
      // Иначе перебором узнаётся, какие ники существуют.
      final fn = read('supabase/functions/login/index.ts');
      expect(fn, contains('const FAILED = { error: "invalid_credentials" }'));
      // Оба отказа отдают одну и ту же константу.
      expect(RegExp(r'return json\(FAILED, 400\)').allMatches(fn).length,
          greaterThanOrEqualTo(3));
      // И почта наружу не уходит ни при каком исходе.
      expect(fn.contains('email:'), isFalse,
          reason: 'адрес попал в ответ функции');
    });

    test('клиент ходит во вход через функцию, а не напрямую', () {
      final account = read('lib/data/account.dart');
      expect(account, contains("supabase.functions.invoke(\n        'login'"));
      expect(account.contains('signInWithPassword'), isFalse,
          reason: 'вход мимо функции снова потребует знать почту');
    });
  });

  group('гостевой аккаунт', () {
    test('это тот же аккаунт, а не новый', () {
      // Регистрация достраивает существующий id: языки, рейтинг и серия
      // принадлежат ему с первой минуты.
      final account = read('lib/data/account.dart');
      expect(account, contains('supabase.auth.signInAnonymously()'));
      expect(account, contains('supabase.auth.updateUser(UserAttributes(email: address))'));
      expect(account.contains('auth.signUp('), isFalse,
          reason: 'signUp завёл бы ВТОРОЙ аккаунт, и прогресс остался бы на первом');
    });

    test('служебная почта выдаётся только тем, кто своей не дал', () {
      expect(kGuestEmailDomain, isNotEmpty);
      final account = read('lib/data/account.dart');
      expect(account, contains("? '\$id@\$kGuestEmailDomain'"));
      expect(account, contains(': email.trim().toLowerCase()'));
    });

    test('выключенное manual linking объясняется словами', () {
      // Документация: «Converting an anonymous user to a permanent user
      // requires linking an identity… This requires you to enable manual
      // linking». Без него достройка падает, и причина не в коде.
      expect(const AccountError('manual_linking_disabled').message,
          contains('manual linking'));
      expect(read('lib/data/account.dart'), contains('manual_linking_disabled'));
    });

    test('занятая почта отправляет входить, а не пробовать снова', () {
      expect(const AccountError('email_exists').message,
          contains('Уже есть аккаунт'));
    });

    test('выключенный гостевой вход объясняется словами', () {
      // Самая частая причина отказа — галка в панели Supabase, а не код.
      expect(const AccountError('anonymous_provider_disabled').message,
          contains('Supabase'));
      expect(read('lib/data/account.dart'), contains('anonymous_provider_disabled'));
    });
  });

  group('что гостю нельзя — на сервере, а не только на экране', () {
    String limits() => read('supabase/migrations/0058_guest_limits.sql');

    test('чужим людям гость писать не может', () {
      // Стена в приложении — это экран. Анонимный игрок остаётся
      // обычным authenticated, и обойти её значит послать запрос мимо
      // приложения. Документация Supabase предупреждает об этом прямо.
      final sql = limits();
      for (final table in [
        'public.match_chat_messages',
        'public.direct_messages',
        'public.friendships',
      ]) {
        expect(sql, contains('on $table'),
            reason: '$table открыт гостю на запись');
      }
      expect(sql, contains('as restrictive for insert'));
    });

    test('политики именно ограничивающие', () {
      // Обычные складываются через ИЛИ: добавить к ним ещё одну
      // разрешающую бесполезно, запретить может только restrictive.
      final sql = limits();
      expect(RegExp(r'as restrictive for').allMatches(sql).length,
          greaterThanOrEqualTo(4));
      expect(sql.contains('as permissive'), isFalse);
    });

    test('игра гостю оставлена', () {
      // Бои, записи, монеты и серия — то, что он делает сам с собой.
      // Ограничение здесь отняло бы ровно то, ради чего его и пускают.
      final sql = limits();
      for (final table in ['matches', 'rounds', 'voice_recordings', 'user_languages']) {
        expect(sql.contains(' public.$table'), isFalse,
            reason: '$table закрыт гостю — Арена станет неиграбельной');
      }
    });

    test('старый токен без claim\'а не считается гостевым', () {
      // У токенов, выписанных до включения анонимного входа, claim'а нет
      // вовсе: `is false` дало бы NULL, то есть отказ живому игроку.
      expect(limits(), contains("is not true"));
      expect(limits().contains("::boolean is false"), isFalse);
    });
  });

  group('куда ведёт первый экран', () {
    test('встречает приветствие, а не форма входа', () {
      expect(read('lib/features/auth/splash_gate.dart'), contains("context.go('/welcome')"));
      final router = read('lib/core/router.dart');
      expect(router, contains("path: '/welcome'"));
      expect(router, contains("path: '/register'"));
      expect(router.contains("path: '/signup'"), isFalse);
      expect(File('lib/features/auth/signup_screen.dart').existsSync(), isFalse);
    });

    test('на приветствии две дороги и обе названы', () {
      final welcome = read('lib/features/auth/welcome_screen.dart');
      expect(welcome, contains("Text('Начать')"));
      expect(welcome, contains("Text('Уже есть аккаунт')"));
      expect(welcome, contains("context.push('/login')"));
    });

    test('вход: одно поле, без регистрации, с возвратом назад', () {
      final login = read('lib/features/auth/login_screen.dart');
      expect(login, contains('Почта или никнейм'));
      expect(login, contains("Text('Начать с начала')"));
      expect(login, contains("Text('Восстановить пароль')"));
      expect(login.contains('Зарегистрироваться'), isFalse);
      expect(login.contains("/signup"), isFalse);
    });

    test('онбординг больше не спрашивает ник', () {
      // Игрок попадает туда сразу после «Начать», ещё ничего про игру не
      // зная: придумывать имя на этом месте — лишний барьер.
      final onboarding = read('lib/features/onboarding/onboarding_screen.dart');
      expect(onboarding.contains("labelText: 'Никнейм'"), isFalse);
      expect(onboarding.contains('_usernameController'), isFalse);
    });
  });

  group('короткая регистрация', () {
    String screen() => read('lib/features/auth/register_screen.dart');

    test('четыре шага в заданном порядке', () {
      final code = screen();
      for (final step in ['Никнейм', 'Email', 'Пароль', 'Аватар']) {
        expect(code, contains(step));
      }
      expect(code.indexOf('Widget _step1'), lessThan(code.indexOf('Widget _step3')));
    });

    test('ник занимается ДО того, как придуман пароль', () {
      // Занятый ник должен выясниться на своём шаге, а не после того,
      // как игрок заполнил всю форму.
      final code = screen();
      expect(code, contains('Account.claimUsername(name)'));
      expect(code.indexOf('claimUsername'), lessThan(code.indexOf('Account.register(')));
    });

    test('почту и аватар можно пропустить, пароль — нет', () {
      final code = screen();
      expect(code, contains("Text('Пропустить')"));
      expect(code, contains("Text('Выбрать аватар потом')"));
      expect(code, contains('Пароль минимум 6 символов'));
      expect(code, contains('Пароли не совпадают'));
    });

    test('почту подтверждать не просят', () {
      // Настройка проекта, а не код: но обещание игроку дано на экране,
      // и если её включат обратно, экран начнёт врать.
      expect(screen(), contains('Подтверждать её не придётся'));
    });
  });

  group('что открыто гостю', () {
    test('только Арена, и замок виден до нажатия', () {
      final shell = read('lib/features/arena/arena_shell.dart');
      expect(shell, contains('Account.isGuest && _index != ArenaTabs.arena'));
      expect(shell, contains('Icons.lock'));
      expect(shell, contains("context.push('/register')"));
    });

    test('после регистрации стена убирается сама', () {
      // Иначе она останется стоять перед уже настоящим игроком.
      expect(read('lib/features/arena/arena_shell.dart'),
          contains('if (mounted) setState(() {});'));
    });
  });
}
