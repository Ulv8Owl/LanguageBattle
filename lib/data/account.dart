/// Аккаунт игрока: гость, короткая регистрация и вход.
///
/// ═══ ПОЧЕМУ ИГРОК НАЧИНАЕТ БЕЗ РЕГИСТРАЦИИ ═══
///
/// Форма входа на первом экране — это счёт, выставленный до того, как
/// показали товар. «Начать» заводит анонимный аккаунт, и всё, что игрок
/// дальше выберет — языки, уровень, рейтинг, серия, — сразу принадлежит
/// ему. Короткая регистрация потом НЕ СОЗДАЁТ НОВЫЙ АККАУНТ, а
/// достраивает этот: тот же id, тот же прогресс.
///
/// ═══ ПОЧЕМУ У ВСЕХ ЕСТЬ ПОЧТА ═══
///
/// Supabase умеет пароль только в паре с почтой. Игрок, отказавшийся её
/// дать, всё равно должен уметь войти по нику и паролю — поэтому ему
/// выдаётся служебный адрес из собственного id. Письма туда не уходят:
/// подтверждение почты выключено в настройках проекта.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase_client.dart';

/// Домен служебных адресов. НЕ НАСТОЯЩИЙ И НЕ ДОЛЖЕН БЫТЬ: писать на
/// такой адрес никто не станет, а игрок о нём даже не узнает.
const String kGuestEmailDomain = 'guest.chrolingo.app';

/// Что пошло не так при регистрации или входе — словами, которые экран
/// умеет показать.
class AccountError implements Exception {
  final String code;
  const AccountError(this.code);

  /// Перевод для игрока. Общий на весь проект: два экрана с разными
  /// формулировками одной и той же беды выглядят как две разные беды.
  String get message => switch (code) {
        'username_taken' => 'Такой никнейм уже занят',
        'username_length' => 'Никнейм от 3 до 20 символов',
        'username_invalid' => 'Только буквы, цифры, дефис и подчёркивание',
        'invalid_credentials' => 'Неверный логин или пароль',
        'anonymous_provider_disabled' =>
          'Гостевой вход выключен в настройках Supabase',
        'manual_linking_disabled' =>
          'В настройках Supabase выключено «Allow manual linking» — '
              'без него гостевой аккаунт нельзя достроить до настоящего',
        'email_exists' =>
          'На эту почту уже есть аккаунт. Войдите в него — «Уже есть аккаунт»',
        _ => 'Не получилось: $code',
      };

  @override
  String toString() => message;
}

class Account {
  Account._();

  static User? get user => supabase.auth.currentUser;

  /// Гость — тот, кто ещё не поставил пароль.
  ///
  /// ПРИЗНАК БЕРЁТСЯ ИЗ ТОКЕНА, А НЕ ИЗ НАШЕЙ ТАБЛИЦЫ: он приходит вместе
  /// с сессией и не требует запроса, а значит, не соврёт при мёртвой сети.
  static bool get isGuest => user?.isAnonymous ?? false;

  static bool get signedIn => supabase.auth.currentSession != null;

  /// Начать без регистрации.
  static Future<void> startAsGuest() async {
    try {
      await supabase.auth.signInAnonymously();
    } on AuthException catch (e) {
      // Самая частая причина — выключенная галка в панели Supabase.
      // Говорим об этом прямо: «Не получилось» отправляет искать ошибку
      // в коде, которой там нет.
      final disabled = e.message.toLowerCase().contains('anonymous');
      throw AccountError(disabled ? 'anonymous_provider_disabled' : e.message);
    }
  }

  /// Имя гостю, если его ещё нет. Пустое место в чужих списках читается
  /// как сбой, а не как «человек не представился».
  static Future<String> ensureGuestName() async {
    final name = await supabase.rpc('ensure_guest_name');
    return name is String ? name : 'Гость';
  }

  /// Занять ник. Отдельным шагом, до пароля: занятый ник должен
  /// выясниться ДО того, как игрок придумал пароль, а не после.
  static Future<void> claimUsername(String username) async {
    try {
      await supabase.rpc('claim_username', params: {'p_username': username});
    } on PostgrestException catch (e) {
      throw AccountError(_codeOf(e.message));
    }
  }

  /// Достроить гостевой аккаунт до настоящего.
  ///
  /// ПОЧТА И ПАРОЛЬ СТАВЯТСЯ ПО ОЧЕРЕДИ, А НЕ ОДНИМ ВЫЗОВОМ. Смена почты
  /// у анонимного аккаунта — это и есть превращение его в обычный;
  /// пароль имеет смысл только после того, как оно случилось.
  static Future<void> register({
    required String password,
    String? email,
  }) async {
    final id = user?.id;
    if (id == null) throw const AccountError('not_authenticated');
    final address = (email == null || email.trim().isEmpty)
        // Почты нет — и не будет. Служебный адрес нужен лишь затем,
        // чтобы Supabase разрешил пароль.
        ? '$id@$kGuestEmailDomain'
        : email.trim().toLowerCase();

    try {
      // ПОРЯДОК ВАЖЕН: смена почты у анонимного аккаунта и есть его
      // превращение в обычный, а пароль имеет смысл только после того,
      // как оно случилось. Документация Supabase про это прямо: «To add
      // a password for the anonymous user, the user's email or phone
      // number needs to be verified first» — подтверждать ничего не
      // придётся только потому, что в проекте выключено Confirm email.
      await supabase.auth.updateUser(UserAttributes(email: address));
      await supabase.auth.updateUser(UserAttributes(password: password));
    } on AuthException catch (e) {
      throw AccountError(_authCodeOf(e));
    }
  }

  /// Вход по нику ИЛИ по почте — одним полем.
  ///
  /// ЧЕРЕЗ EDGE FUNCTION, А НЕ НАПРЯМУЮ. Supabase умеет вход только по
  /// почте, а спрашивать «какая почта у этого ника» с клиента значит
  /// открыть всем превращение списка ников в список адресов. Функция
  /// отдаёт только сессию и только при верном пароле.
  static Future<void> signIn({
    required String login,
    required String password,
  }) async {
    try {
      final response = await supabase.functions.invoke(
        'login',
        body: {'login': login.trim(), 'password': password},
      );
      final data = response.data;
      final refresh = data is Map ? data['refresh_token'] as String? : null;
      final access = data is Map ? data['access_token'] as String? : null;
      if (refresh == null || refresh.isEmpty) {
        throw const AccountError('invalid_credentials');
      }
      await supabase.auth.setSession(refresh, accessToken: access);
    } on FunctionException {
      // Функция отвечает одинаково и на неверный ник, и на неверный
      // пароль — специально, чтобы перебором нельзя было узнать, какие
      // ники существуют. Клиенту тоже незачем их различать.
      throw const AccountError('invalid_credentials');
    }
  }

  static Future<void> signOut() => supabase.auth.signOut();

  /// Две причины отказа при достройке аккаунта объясняются не кодом, а
  /// настройкой проекта или чужим аккаунтом — и обе надо назвать словами,
  /// иначе искать будут в коде, где ничего нет.
  static String _authCodeOf(AuthException e) {
    final code = e.code ?? '';
    final text = '$code ${e.message}'.toLowerCase();
    if (text.contains('manual_linking') || text.contains('manual linking')) {
      return 'manual_linking_disabled';
    }
    if (text.contains('identity_already_exists') ||
        text.contains('email_exists') ||
        text.contains('already registered') ||
        text.contains('already been registered')) {
      return 'email_exists';
    }
    return e.message;
  }

  /// Postgres отдаёт наши raise exception целой фразой. Берём из неё
  /// код — по нему переводится сообщение.
  static String _codeOf(String message) {
    for (final code in const [
      'username_taken',
      'username_length',
      'username_invalid',
    ]) {
      if (message.contains(code)) return code;
    }
    return message;
  }
}
