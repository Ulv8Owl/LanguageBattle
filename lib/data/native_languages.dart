import '../core/supabase_client.dart';

/// Один родной язык игрока — строка user_native_languages (миграция 0025).
class NativeLanguage {
  final String code;
  final bool isPrimary;

  const NativeLanguage({required this.code, required this.isPrimary});

  factory NativeLanguage.fromRow(Map<String, dynamic> row) => NativeLanguage(
        code: row['language_code'] as String,
        isPrimary: row['is_primary'] as bool? ?? false,
      );
}

/// До скольки родных языков можно добавить — тот же лимит зашит и в RPC
/// (native_limit_reached), здесь только для UI (спрятать «+», когда некуда).
const int maxNativeLanguages = 6;

/// Все родные языки текущего игрока — обёртка над user_native_languages и
/// тремя RPC (add/remove/set_primary_native_language, миграция 0025).
///
/// users.native_language всегда равен тому, что здесь primary — эту связь
/// держит сервер (триггер + сами RPC), клиенту достаточно звать RPC и
/// перечитывать список.
class NativeLanguages {
  NativeLanguages._();

  static Future<List<NativeLanguage>> fetch(String userId) async {
    final rows = await supabase
        .from('user_native_languages')
        .select('language_code, is_primary')
        .eq('user_id', userId)
        .order('created_at');
    return rows.map((r) => NativeLanguage.fromRow(Map<String, dynamic>.from(r))).toList();
  }

  static Future<void> add(String code) =>
      supabase.rpc('add_native_language', params: {'p_language_code': code});

  /// Бросает 'must_keep_one_native', если это последний родной язык, —
  /// экран должен ловить это сам и объяснять, а не показывать сырую ошибку.
  static Future<void> remove(String code) =>
      supabase.rpc('remove_native_language', params: {'p_language_code': code});

  static Future<void> setPrimary(String code) =>
      supabase.rpc('set_primary_native_language', params: {'p_language_code': code});
}
