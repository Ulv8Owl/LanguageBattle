import '../core/supabase_client.dart';
import 'player_rating.dart';

/// Языковая пара — ДВА ЯЗЫКА И БОЛЬШЕ НИЧЕГО.
///
/// ЧТО БЫЛО. «Родной язык» жил в трёх местах сразу: в `users.native_language`,
/// в отдельном реестре `user_native_languages` и в самой паре
/// (`user_languages.native_for`). Пару можно было завести только «от» языка,
/// заранее записанного в реестр, и именно этот реестр был единственной
/// причиной, по которой часть пар завести не удавалось. Три хранилища
/// одного факта расходятся всегда — вопрос только когда.
///
/// ЧТО СТАЛО. Строка `user_languages` с `role = 'learning'` И ЕСТЬ пара:
/// [speaks] — язык, с которого игрок переводит, [learns] — который изучает.
/// Реестра нет, ограничений на количество пар нет, никакой «главный родной»
/// ни на что не влияет. Всё, что коду нужно знать про язык игрока, он берёт
/// из активной пары.
class LanguagePair {
  /// Язык, с которого игрок переводит. В базе — `native_for`.
  ///
  /// Раньше он назывался родным, и это сбивало: язык пары и «родной язык
  /// аккаунта» — разные вещи, а имя было одно на оба.
  final String speaks;

  /// Язык, который игрок изучает. В базе — `language_code`.
  final String learns;

  /// Играет ли игрок сейчас этой парой. Активная всегда ровно одна.
  final bool isActive;

  /// Рейтинг, лига и уровень — свои у каждой пары.
  final PlayerRating rating;

  const LanguagePair({
    required this.speaks,
    required this.learns,
    required this.isActive,
    required this.rating,
  });

  /// Что выбрать в базе, чтобы собрать пару. Один список на все экраны:
  /// разные наборы колонок в разных местах — это разные представления об
  /// одном и том же, и однажды они разойдутся.
  static const columns = 'language_code, native_for, is_active, ${PlayerRating.columns}';

  factory LanguagePair.fromRow(Map<String, dynamic> row) => LanguagePair(
        speaks: (row['native_for'] as String?) ?? '',
        learns: (row['language_code'] as String?) ?? '',
        isActive: row['is_active'] as bool? ?? false,
        rating: PlayerRating.fromRow(row),
      );

  /// Совпадают ли пары. Пара опознаётся ОБОИМИ языками: ru→es и en→es —
  /// разные пары с разным рейтингом, и по одному изучаемому их не отличить.
  bool same(String speaks, String learns) => this.speaks == speaks && this.learns == learns;

  @override
  String toString() => '$speaks→$learns';
}

/// Все пары игрока, кроме скрытых с профиля.
///
/// Скрытая пара не удалена: у неё остались рейтинг и история, и вернуть её
/// можно повторным добавлением (см. `add_language_pair`).
Future<List<LanguagePair>> fetchLanguagePairs([String? userId]) async {
  final rows = await supabase
      .from('user_languages')
      .select(LanguagePair.columns)
      .eq('user_id', userId ?? currentUserId)
      .eq('role', 'learning')
      .isFilter('hidden_at', null)
      // Активная первой, дальше по языкам — чтобы порядок плашек не прыгал
      // от запроса к запросу.
      .order('is_active', ascending: false)
      .order('native_for')
      .order('language_code');
  return rows.map((r) => LanguagePair.fromRow(Map<String, dynamic>.from(r))).toList();
}

/// Пара, которой игрок играет сейчас. null — пар нет вовсе.
///
/// Если активной не отмечено ни одной (так бывает у старых аккаунтов),
/// берём первую: показать игроку пустоту там, где пары есть, хуже, чем
/// выбрать за него.
Future<LanguagePair?> fetchActivePair([String? userId]) async {
  final pairs = await fetchLanguagePairs(userId);
  if (pairs.isEmpty) return null;
  for (final pair in pairs) {
    if (pair.isActive) return pair;
  }
  return pairs.first;
}

/// Заводит пару. Ограничение ровно одно: язык нельзя учить у самого себя.
///
/// Бросает `pair_already_exists`, если такая пара уже есть, и
/// `target_equals_native`, если языки совпали. Скрытую пару возвращает на
/// профиль вместо создания второй такой же.
Future<void> addLanguagePair({required String speaks, required String learns}) =>
    supabase.rpc('add_language_pair', params: {
      'p_target_language': learns,
      'p_native_language': speaks,
    });

/// Делает пару активной. Рейтинги обеих пар не трогаются: это просто смена
/// того, какой парой игрок сейчас играет.
Future<void> setActiveLanguagePair({required String speaks, required String learns}) =>
    supabase.rpc('set_active_language_pair', params: {
      'p_target_language': learns,
      'p_native_language': speaks,
    });

/// Убирает пару с профиля, не удаляя её: рейтинг, лига и история остаются.
Future<void> hideLanguagePair({required String speaks, required String learns}) =>
    supabase.rpc('hide_language_pair', params: {
      'p_target_language': learns,
      'p_native_language': speaks,
    });

/// Меняет ОБА языка существующей пары.
///
/// Нужна там, где списка пар ещё нет, — на проверке уровня при регистрации:
/// игрок, ошибившийся с языками, до сих пор не мог это исправить, а завести
/// рядом вторую пару значило бы оставить ему ненужную первую навсегда.
///
/// Рейтинг и подтверждённый уровень при этом сбрасываются: они относились к
/// прежнему изучаемому языку.
Future<void> retargetLanguagePair({
  required LanguagePair pair,
  required String speaks,
  required String learns,
}) =>
    supabase.rpc('retarget_language_pair', params: {
      'p_old_target': pair.learns,
      'p_old_native': pair.speaks,
      'p_new_target': learns,
      'p_new_native': speaks,
    });

/// Человеческая причина отказа вместо сырого текста исключения.
///
/// ЕДИНСТВЕННЫЙ ЗАПРЕТ — совпадение языков в паре. Язык, который игрок уже
/// где-то указал своим, изучаемым в другой паре быть может: он вправе учить
/// английский от русского и русский от английского одновременно.
String languagePairError(Object e) {
  final text = e.toString();
  if (text.contains('target_equals_native')) {
    return 'Нельзя учить язык у самого себя — выбери другой изучаемый или '
        'другой язык, с которого переводишь.';
  }
  if (text.contains('pair_already_exists')) return 'Такая пара уже есть.';
  return 'Не удалось сохранить пару: $e';
}
