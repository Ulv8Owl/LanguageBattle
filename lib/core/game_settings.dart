import 'supabase_client.dart';

/// Переключатели игрока: где в раунде участвует модель.
///
/// ЗАЧЕМ КЭШ В ПАМЯТИ. Значения нужны экрану разбора в момент отрисовки —
/// то есть синхронно, без await. Тянуть их из базы прямо там значило бы
/// либо мигать разбором, пока запрос летит, либо держать в каждом экране
/// по своему состоянию загрузки ради двух булевых полей.
///
/// ИСТИНА ВСЁ РАВНО НА СЕРВЕРЕ. Здесь только копия: воркер читает те же
/// колонки сам и по ним решает, звать ли модель. Клиентская копия влияет
/// ровно на одно — какой текст показать, когда есть оба варианта. Даже
/// разойдясь с сервером, она не может ни исказить балл, ни потратить
/// энергию.
class GameSettings {
  GameSettings._();

  /// Балл выставляет модель. Выключено — считается по элементам фразы.
  static bool llmScoring = false;

  /// Разбор пишет модель. Выключено — берётся из датасета пояснений.
  static bool llmExplanations = false;

  /// Подтягивает настройки из профиля.
  ///
  /// Молча оставляет прежние значения при сбое: настройки — не то, ради
  /// чего стоит показывать ошибку на входе в игру. Значения по умолчанию
  /// совпадают с колонками в базе, так что промах кэша даёт ровно то же
  /// поведение, что и успешное чтение у нетронутого профиля.
  static Future<void> load() async {
    try {
      // Именно currentUser?.id, а не currentUserId: до входа в аккаунт
      // второй бросает, и загрузка настроек уронила бы стартовый экран
      // ради двух булевых полей, которые до входа всё равно не нужны.
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) return;
      final row = await supabase
          .from('users')
          .select('llm_scoring_enabled, llm_explanations_enabled')
          .eq('id', uid)
          .maybeSingle();
      if (row == null) return;
      llmScoring = row['llm_scoring_enabled'] == true;
      llmExplanations = row['llm_explanations_enabled'] == true;
    } catch (_) {
      // Оставляем то, что было: см. комментарий выше.
    }
  }

  /// Сохраняет один переключатель и сразу обновляет кэш.
  ///
  /// Кэш правится ДО запроса, чтобы переключатель не «отскакивал» назад на
  /// время сети. При ошибке значение возвращается — иначе экран показывал
  /// бы состояние, которого в базе нет.
  static Future<void> setLlmScoring(bool value) async {
    final previous = llmScoring;
    llmScoring = value;
    try {
      await supabase
          .from('users')
          .update({'llm_scoring_enabled': value})
          .eq('id', currentUserId);
    } catch (e) {
      llmScoring = previous;
      rethrow;
    }
  }

  static Future<void> setLlmExplanations(bool value) async {
    final previous = llmExplanations;
    llmExplanations = value;
    try {
      await supabase
          .from('users')
          .update({'llm_explanations_enabled': value})
          .eq('id', currentUserId);
    } catch (e) {
      llmExplanations = previous;
      rethrow;
    }
  }
}
