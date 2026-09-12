import '../core/supabase_client.dart';
import 'player_rating.dart';

/// Два языка игрока: на котором говорит и который учит.
///
/// ЧТО БЫЛО. Языковых пар было сколько угодно, и весь прогресс принадлежал
/// ПАРЕ: у ru→en и es→en были разные рейтинги, а монеты и опыт при этом
/// лежали одной кучей на аккаунт. То есть учёт одного и того же игрока шёл
/// сразу по двум несовместимым правилам, а игрок выбирал пару в профиле,
/// не понимая, что выбирает вместе с ней и свой рейтинг.
///
/// ЧТО СТАЛО. Языка два, и они выбираются в настройках. Весь прогресс —
/// рейтинг, лига, монеты, опыт, достижения — принадлежит ИЗУЧАЕМОМУ языку
/// (миграция 0051). Язык, с которого игрок переводит, остаётся при этой же
/// строке (`native_for`), но ничего не делит: сменив его, игрок не теряет
/// накопленное.
class MyLanguages {
  /// Язык, на котором игрок говорит. В базе — `user_languages.native_for`
  /// и `users.native_language` (одно и то же значение).
  final String speaks;

  /// Язык, который игрок изучает. В базе — `language_code`. ИМЕННО ОН
  /// ключ ко всему прогрессу.
  final String learns;

  /// Рейтинг, лига и уровень — свои у каждого изучаемого языка.
  final PlayerRating rating;

  const MyLanguages({
    required this.speaks,
    required this.learns,
    required this.rating,
  });

  /// Что выбрать в базе. Один список на все экраны: разные наборы колонок
  /// в разных местах — это разные представления об одном и том же, и
  /// однажды они разойдутся.
  static const columns = 'language_code, native_for, ${PlayerRating.columns}';

  factory MyLanguages.fromRow(Map<String, dynamic> row) => MyLanguages(
        speaks: (row['native_for'] as String?) ?? '',
        learns: (row['language_code'] as String?) ?? '',
        rating: PlayerRating.fromRow(row),
      );

  @override
  String toString() => '$speaks→$learns';
}

/// Языки игрока. null — их ещё не выбрали (аккаунт на середине регистрации).
Future<MyLanguages?> fetchMyLanguages([String? userId]) async {
  final row = await supabase
      .from('user_languages')
      .select(MyLanguages.columns)
      .eq('user_id', userId ?? currentUserId)
      .eq('role', 'learning')
      .eq('is_active', true)
      .limit(1)
      .maybeSingle();
  if (row == null) return null;
  return MyLanguages.fromRow(Map<String, dynamic>.from(row));
}

/// Сохраняет оба языка сразу.
///
/// ОБА, А НЕ ПО ОДНОМУ: языки связаны запретом «нельзя учить язык у самого
/// себя», и проверить его, меняя по одному, нельзя — промежуточное
/// состояние всегда оказывалось бы запрещённым.
///
/// Прогресс по прежнему изучаемому языку остаётся при нём: вернувшись,
/// игрок найдёт свой рейтинг, монеты и достижения на месте.
Future<void> setMyLanguages({required String speaks, required String learns}) =>
    supabase.rpc('set_my_languages', params: {
      'p_speaks': speaks,
      'p_learns': learns,
    });

/// Человеческая причина отказа вместо сырого текста исключения.
String myLanguagesError(Object e) {
  final text = e.toString();
  if (text.contains('target_equals_native')) {
    return 'Нельзя учить язык у самого себя — выбери другой изучаемый или '
        'другой язык, на котором говоришь.';
  }
  if (text.contains('language_required')) return 'Выбери оба языка.';
  return 'Не удалось сохранить языки: $e';
}
