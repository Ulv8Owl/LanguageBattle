import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_strings.dart';
import 'supabase_client.dart';

/// Язык интерфейса приложения.
///
/// Хранится в ДВУХ местах, и это не дублирование по недосмотру:
///  * users.interface_language на сервере — источник истины, чтобы выбор
///    переезжал вместе с аккаунтом на новое устройство;
///  * SharedPreferences на устройстве — кэш, чтобы первый экран рисовался
///    на нужном языке СРАЗУ, не дожидаясь ответа сервера и не мигая с
///    русского на английский через полсекунды после запуска.
///
/// При расхождении побеждает сервер: [load] сначала поднимает кэш, затем
/// дочитывает серверное значение и обновляет кэш.
class AppLocale {
  AppLocale._();

  static const String _prefsKey = 'interface_language';

  /// Языки, на которые переведён интерфейс. Список короткий намеренно:
  /// добавить сюда язык можно только вместе с полным набором строк в
  /// AppStrings, иначе игрок увидит наполовину пустые экраны. Тот же
  /// список ограничением проверяет база (users_interface_language_check).
  static const List<String> supported = ['ru', 'en'];

  /// Как язык называется на себе самом — так его и показывать в списке.
  static const Map<String, String> endonyms = {
    'ru': 'Русский',
    'en': 'English',
  };

  /// Текущий язык. Слушается на самом верху дерева (LanguageBattleApp),
  /// поэтому смена языка перерисовывает всё приложение целиком — так не
  /// нужно протаскивать локаль через каждый экран.
  static final ValueNotifier<String> code = ValueNotifier<String>('ru');

  /// Строки текущего языка. Читается прямо в build() экранов.
  static AppStrings get strings => code.value == 'en' ? AppStrings.en : AppStrings.ru;

  /// Поднять сохранённый выбор. Вызывается один раз при старте, ДО
  /// runApp — иначе первый кадр успеет нарисоваться на языке по умолчанию.
  ///
  /// Ошибки глотаются намеренно: не тот язык интерфейса — неприятность, а
  /// падение на старте из-за недоступного хранилища или сети — потеря
  /// приложения целиком.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_prefsKey);
      if (cached != null && supported.contains(cached)) {
        code.value = cached;
      }
    } catch (_) {
      // Хранилище недоступно — остаёмся на языке по умолчанию.
    }
    await refreshFromServer();
  }

  /// Дочитать язык с сервера и подтянуть кэш под него. Отдельный метод,
  /// потому что вызывается ещё и после входа в аккаунт: до входа
  /// currentUserId нет, и серверное значение прочитать неоткуда.
  static Future<void> refreshFromServer() async {
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) return;
      final row = await supabase
          .from('users')
          .select('interface_language')
          .eq('id', uid)
          .maybeSingle();
      final remote = row?['interface_language'] as String?;
      if (remote == null || !supported.contains(remote)) return;
      if (remote != code.value) code.value = remote;
      await _cache(remote);
    } catch (_) {
      // Нет сети — играем на том, что в кэше.
    }
  }

  /// Сменить язык: экран перерисовывается сразу, сервер догоняет.
  ///
  /// Порядок именно такой. Если сначала ждать сервера, интерфейс замрёт на
  /// секунду после нажатия, а при отсутствии сети не переключится вовсе —
  /// хотя ничего, кроме локального выбора, для этого не нужно.
  static Future<void> set(String value) async {
    if (!supported.contains(value)) return;
    code.value = value;
    await _cache(value);
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) return;
      await supabase
          .from('users')
          .update({'interface_language': value})
          .eq('id', uid);
    } catch (_) {
      // Не долетело — на этом устройстве язык всё равно сменился, а на
      // сервер уедет при следующей смене.
    }
  }

  static Future<void> _cache(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, value);
    } catch (_) {
      // Кэш не обязателен: без него язык просто дочитается с сервера.
    }
  }
}
