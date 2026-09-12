/// Достижения игрока.
///
/// ПОКА ОНО ОДНО — «Неудержимый», и это не заготовка под десять других.
/// Достижение, придуманное «чтобы было», ничего не измеряет и выдаётся
/// всем подряд; здесь заведён механизм и одна настоящая ступенчатая
/// награда, а остальные появятся, когда станет понятно, за что их давать.
///
/// ВЫДАЁТ ИХ СЕРВЕР (award_unstoppable, миграция 0050). Клиент только
/// сообщает, сколько раундов игрок продержался, и показывает, что пришло в
/// ответ: достижение, которое клиент выдаёт себе сам, — не достижение.
library;

import '../core/supabase_client.dart';

/// Вид достижения. Ступени внутри вида — числа: 5, 10, 15 раундов.
enum AchievementKind {
  unstoppable(
    slug: 'unstoppable',
    title: 'Неудержимый',
    // Описание одно на все ступени, n подставляется — так и просили.
    description: 'Продержаться в одиночной игре n раундов подряд',
    // Первая ступень. Она же — то, что показано серым, пока достижения нет.
    firstTier: 5,
  );

  final String slug;
  final String title;
  final String description;
  final int firstTier;

  const AchievementKind({
    required this.slug,
    required this.title,
    required this.description,
    required this.firstTier,
  });

  /// Описание конкретной ступени: то же предложение, но с числом вместо n.
  String describe(int tier) => description.replaceAll('n', '$tier');

  /// Что сделать, чтобы получить. Показывается на серой, ещё не полученной.
  String howTo(int tier) => 'Продержись в одиночной игре $tier раундов подряд';

  static AchievementKind? bySlug(String slug) {
    for (final kind in AchievementKind.values) {
      if (kind.slug == slug) return kind;
    }
    return null;
  }
}

/// Одна полученная ступень.
class Achievement {
  final AchievementKind kind;
  final int tier;
  final DateTime earnedAt;

  const Achievement({required this.kind, required this.tier, required this.earnedAt});
}

/// Что показать в профиле по одному виду достижений.
///
/// РОВНО ПО ОДНОЙ ПЛАШКЕ НА ВИД. Есть полученные — показываем САМУЮ
/// ВЫСОКУЮ ступень и ни одной серой рядом: серая при уже полученном
/// достижении выглядела бы как «ты это ещё не сделал». Нет ни одной —
/// показываем одну серую, первую ступень.
class AchievementSlot {
  final AchievementKind kind;

  /// Полученная ступень или null — тогда плашка серая.
  final int? earnedTier;

  /// Ступень, о которой рассказывает серая плашка.
  final int nextTier;

  const AchievementSlot({
    required this.kind,
    required this.earnedTier,
    required this.nextTier,
  });

  bool get earned => earnedTier != null;

  /// Текст, который видит игрок по нажатию.
  String get detail =>
      earned ? kind.describe(earnedTier!) : kind.howTo(nextTier);
}

/// Все достижения игрока, разложенные по одной плашке на вид.
Future<List<AchievementSlot>> loadAchievements([String? userId]) async {
  final id = userId ?? currentUserId;
  final rows = await supabase
      .from('achievements')
      .select('kind, tier')
      .eq('user_id', id);

  final bestByKind = <String, int>{};
  for (final row in rows) {
    final slug = row['kind'] as String?;
    final tier = (row['tier'] as num?)?.toInt();
    if (slug == null || tier == null) continue;
    final best = bestByKind[slug];
    if (best == null || tier > best) bestByKind[slug] = tier;
  }

  return [
    for (final kind in AchievementKind.values)
      AchievementSlot(
        kind: kind,
        earnedTier: bestByKind[kind.slug],
        nextTier: kind.firstTier,
      ),
  ];
}

/// Сообщает серверу, сколько раундов подряд игрок продержался, и возвращает
/// ТОЛЬКО НОВЫЕ ступени — те, которых у него ещё не было.
///
/// НИКОГДА НЕ БРОСАЕТ: достижение — украшение поверх игры, и ронять из-за
/// него раунд нельзя. Не выдалось сейчас — выдастся на следующем вызове,
/// функция идемпотентна и добирает пропущенные ступени.
Future<List<int>> awardUnstoppable(int rounds) async {
  try {
    final result = await supabase.rpc('award_unstoppable', params: {'p_rounds': rounds});
    if (result is Map && result['new_tiers'] is List) {
      return (result['new_tiers'] as List).map((t) => (t as num).toInt()).toList();
    }
  } catch (_) {
    // Молча: см. док-комментарий.
  }
  return const [];
}
