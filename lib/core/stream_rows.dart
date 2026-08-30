/// Одна строка на id.
///
/// Стрим Supabase отдаёт снимок своего локального кэша, и этот кэш умеет
/// содержать одну и ту же строку дважды. В ленте боя это выглядело как два
/// одинаковых «Раунд 1 из 10»: и фраза, и подпись «Скажи это по-английски»
/// дублировались, потому что это буквально один и тот же раунд.
List<Map<String, dynamic>> dedupeById(List<Map<String, dynamic>> rows) {
  final byId = <Object?, Map<String, dynamic>>{};
  for (final row in rows) {
    byId[row['id']] = row;
  }
  return byId.values.toList();
}
