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
        'cefr_level': 'C2',
        'elo': 1000,
        'league': 'bronze',
        // Активна всегда изучаемая пара, не родной язык.
        'is_active': false,
      },
      {
        'user_id': userId,
        'language_code': targetLanguage,
        'role': 'learning',
        'cefr_level': 'A1',
        'elo': 1000,
        'league': 'bronze',
        'is_active': true,
      },
    ];
