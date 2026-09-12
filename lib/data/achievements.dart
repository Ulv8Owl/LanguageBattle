/// Достижения игрока.
///
/// ВЫДАЁТ ИХ ТОЛЬКО СЕРВЕР (миграции 0050 и 0051). Клиент сообщает о
/// событии — сколько раундов продержался, какую запись прослушал, какие
/// слова выучил — и показывает, что пришло в ответ: достижение, которое
/// клиент выдаёт себе сам, — не достижение, а настройка.
///
/// КАЖДОЕ ПРИНАДЛЕЖИТ ИЗУЧАЕМОМУ ЯЗЫКУ (миграция 0051). «Покоритель» за
/// десять побед на английском не висит на только что начатом испанском:
/// иначе плашка рассказывала бы про игрока неправду.
library;

import '../core/supabase_client.dart';
import 'my_languages.dart';

/// Вид достижения. Ступени внутри вида — числа: 5, 10, 15 раундов и т.п.
///
/// ЛЕСТНИЦЫ ЗДЕСЬ И В SQL (achievement_tiers_reached, миграция 0051)
/// ОБЯЗАНЫ СОВПАДАТЬ. Дублирование вынужденное — Dart и Postgres не могут
/// делить один файл, — и проверяется тестом.
enum AchievementKind {
  unstoppable(
    slug: 'unstoppable',
    title: 'Неудержимый',
    // Описание одно на все ступени, n подставляется — так и просили.
    description: 'Продержаться в одиночной игре n раундов подряд',
    howToTemplate: 'Продержись в одиночной игре n раундов подряд',
    // Первая ступень. Она же — то, что показано серым, пока достижения нет.
    firstTier: 5,
  ),
  conqueror(
    slug: 'conqueror',
    title: 'Покоритель',
    description: 'Одержать n побед в PvP-режимах',
    howToTemplate: 'Одержи n побед в Состязании или Дуэли',
    firstTier: 1,
  ),
  auditor(
    slug: 'auditor',
    title: 'Аудитор',
    description: 'Прослушать n голосовых записей от носителей изучаемого языка',
    howToTemplate: 'Прослушай n голосовых записей от носителей изучаемого языка',
    firstTier: 1,
  ),
  scholar(
    slug: 'scholar',
    title: 'Знаток',
    description: 'Выучить n слов в режиме Тренировки',
    howToTemplate: 'Выучи n слов в режиме Тренировки',
    firstTier: 10,
  ),
  social(
    slug: 'social',
    title: 'Социальный',
    description: 'Начать общение с n игроками изучаемого языка',
    howToTemplate: 'Напиши первым n игрокам изучаемого языка',
    firstTier: 1,
  );

  final String slug;
  final String title;
  final String description;
  final String howToTemplate;
  final int firstTier;

  const AchievementKind({
    required this.slug,
    required this.title,
    required this.description,
    required this.howToTemplate,
    required this.firstTier,
  });

  /// Описание конкретной ступени: то же предложение, но с числом вместо n.
  String describe(int tier) => description.replaceAll('n', '$tier');

  /// Что сделать, чтобы получить. Показывается на серой, ещё не полученной.
  String howTo(int tier) => howToTemplate.replaceAll('n', '$tier');

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

/// Все достижения игрока ПО ЕГО ИЗУЧАЕМОМУ ЯЗЫКУ, по одной плашке на вид.
Future<List<AchievementSlot>> loadAchievements([String? userId]) async {
  final id = userId ?? currentUserId;
  final languages = await fetchMyLanguages(id);

  final bestByKind = <String, int>{};
  if (languages != null) {
    final rows = await supabase
        .from('achievements')
        .select('kind, tier')
        .eq('user_id', id)
        .eq('language_code', languages.learns);

    for (final row in rows) {
      final slug = row['kind'] as String?;
      final tier = (row['tier'] as num?)?.toInt();
      if (slug == null || tier == null) continue;
      final best = bestByKind[slug];
      if (best == null || tier > best) bestByKind[slug] = tier;
    }
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

/// Новые ступени одного вида — то, что показывают игроку сразу после
/// события. Пустой список означает «ничего нового», а не ошибку.
class AchievementGain {
  final AchievementKind kind;
  final int tier;

  const AchievementGain(this.kind, this.tier);

  String get title => kind.title;

  String get detail => kind.describe(tier);
}

/// Общий разбор ответа выдающих RPC: `{"new_tiers": [...]}`.
List<AchievementGain> _gains(AchievementKind kind, Object? result) {
  if (result is Map && result['new_tiers'] is List) {
    return [
      for (final t in result['new_tiers'] as List)
        AchievementGain(kind, (t as num).toInt()),
    ];
  }
  return const [];
}

/// Сообщает серверу, сколько раундов подряд игрок продержался.
///
/// НИКОГДА НЕ БРОСАЕТ: достижение — украшение поверх игры, и ронять из-за
/// него раунд нельзя. Не выдалось сейчас — выдастся на следующем вызове:
/// функция идемпотентна и добирает пропущенные ступени. Это относится ко
/// всем вызовам ниже.
Future<List<AchievementGain>> awardUnstoppable(int rounds) async {
  try {
    final result = await supabase.rpc('award_unstoppable', params: {'p_rounds': rounds});
    return _gains(AchievementKind.unstoppable, result);
  } catch (_) {
    return const [];
  }
}

/// Отмечает прослушанную голосовую запись соперника («Аудитор»).
///
/// Засчитывается она или нет, решает сервер: запись должна быть чужой, от
/// НОСИТЕЛЯ изучаемого языка, и из матча, в котором игрок участвовал.
Future<List<AchievementGain>> noteVoiceListen(String recordingId) async {
  try {
    final result = await supabase
        .rpc('note_voice_listen', params: {'p_recording_id': recordingId});
    return _gains(AchievementKind.auditor, result);
  } catch (_) {
    return const [];
  }
}

/// Отмечает слова, выученные в Тренировке («Знаток»).
///
/// ПАЧКОЙ, А НЕ ПО ОДНОМУ: карточки проходят колодой, и звать сервер на
/// каждое слово значило бы двадцать запросов вместо одного. Повторы
/// сервер отбрасывает сам — слово засчитывается раз в жизни.
Future<List<AchievementGain>> noteLearnedWords(List<String> words) async {
  if (words.isEmpty) return const [];
  try {
    final result = await supabase.rpc('note_learned_words', params: {'p_words': words});
    return _gains(AchievementKind.scholar, result);
  } catch (_) {
    return const [];
  }
}

/// Пересчитывает «Социального» — со сколькими игроками изучаемого языка
/// игрок начал общение. Зовётся после отправки личного сообщения.
Future<List<AchievementGain>> syncSocialAchievement() async {
  try {
    final result = await supabase.rpc('sync_social_achievement');
    return _gains(AchievementKind.social, result);
  } catch (_) {
    return const [];
  }
}
