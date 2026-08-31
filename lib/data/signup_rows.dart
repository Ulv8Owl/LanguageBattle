/// Строки user_languages, создаваемые при заполнении профиля.
///
/// Вынесено из экрана ради одного-единственного свойства, которое иначе
/// проверить нечем: у всех строк групповой вставки набор ключей ОБЯЗАН
/// совпадать.
///
/// PostgREST на групповой вставке строит один список столбцов из объединения
/// ключей всех объектов и подставляет явный NULL там, где в объекте ключа
/// нет, — а вовсе не значение по умолчанию из схемы. Один пропущенный
/// is_active в родной строке (в схеме `not null default false`) ронял
/// регистрацию каждого нового игрока на самом первом экране, и по коду это
/// не бросалось в глаза: строки выглядели просто «немного разными».
///
/// Рейтинговых столбцов здесь нет намеренно. rating/rating_deviation/
/// volatility заводит схема (1500 / 350 / 0.06 — стартовые значения
/// Glicko-2), а elo, league_rating, league и cefr_level считает по ним
/// триггер trg_sync_rating_mirrors (миграция 0023). Прислать их отсюда
/// значило бы прислать числа, которые тут же будут перезаписаны.
List<Map<String, dynamic>> signupLanguageRows({
  required String userId,
  required String nativeLanguage,
  required String targetLanguage,
}) =>
    [
      {
        'user_id': userId,
        'language_code': nativeLanguage,
        'role': 'native',
        // Активна всегда изучаемая пара, не родной язык.
        'is_active': false,
      },
      {
        'user_id': userId,
        'language_code': targetLanguage,
        'role': 'learning',
        'is_active': true,
      },
    ];
