/// Переписка: мини-чат матча и чат с друзьями.
///
/// ПОЧЕМУ ОДИН ФАЙЛ НА ДВА ЧАТА. Разные у них только таблица и правило
/// доступа (см. миграцию 0049); всё остальное — модель сообщения, разбор
/// строки, отправка, живая подписка — совпадает слово в слово. Две копии
/// этого кода разошлись бы на первой же правке, и чат матча стал бы вести
/// себя не так, как чат друзей, без всякой на то причины.
///
/// ЧЕГО ЗДЕСЬ НЕТ: непрочитанных, доставки, «печатает…». Ни того, ни
/// другого не просили, а каждое требует отдельного решения о том, что
/// видит вторая сторона.
library;

import 'dart:async';

import '../core/supabase_client.dart';
import 'achievements.dart';

/// Сообщение мини-чата матча.
class MatchChatMessage {
  final String id;
  final String matchId;
  final String userId;
  final String body;

  /// 'text' — обычное сообщение или эмодзи; 'rematch' — вызов на реванш;
  /// 'rematch_started' — реванш принят, бой создан.
  final String kind;

  /// Куда идти по принятому реваншу. Не пусто только у 'rematch_started'.
  final String? newMatchId;
  final DateTime createdAt;

  const MatchChatMessage({
    required this.id,
    required this.matchId,
    required this.userId,
    required this.body,
    required this.kind,
    required this.newMatchId,
    required this.createdAt,
  });

  bool get isRematchOffer => kind == 'rematch';
  bool get isRematchStarted => kind == 'rematch_started';

  factory MatchChatMessage.fromRow(Map<String, dynamic> row) => MatchChatMessage(
        id: row['id'] as String,
        matchId: row['match_id'] as String,
        userId: row['user_id'] as String,
        body: ((row['body'] as String?) ?? '').trim(),
        kind: (row['kind'] as String?) ?? 'text',
        newMatchId: row['new_match_id'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}

/// Живая лента мини-чата матча, по возрастанию времени.
///
/// Порядок держим сами: у стрима supabase_flutter `ascending` по умолчанию
/// false, и сообщения приходили бы новыми вверх.
Stream<List<MatchChatMessage>> matchChatStream(String matchId) => supabase
    .from('match_chat_messages')
    .stream(primaryKey: ['id'])
    .eq('match_id', matchId)
    .map((rows) => rows.map(MatchChatMessage.fromRow).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt)));

/// Отправляет сообщение в мини-чат матча. `kind` проверяется политикой:
/// клиент может писать только 'text' и 'rematch'.
Future<void> sendMatchMessage(String matchId, String body, {String kind = 'text'}) async {
  final text = body.trim();
  if (text.isEmpty) return;
  await supabase.from('match_chat_messages').insert({
    'match_id': matchId,
    'user_id': currentUserId,
    'body': text.length > 500 ? text.substring(0, 500) : text,
    'kind': kind,
  });
}

/// Вызывает соперника на реванш — обычным сообщением в том же чате.
///
/// Отдельной таблицы приглашений нет намеренно: вызов должен быть ВИДЕН
/// обоим ровно там, где они сейчас смотрят, а это чат.
Future<void> offerRematch(String matchId) =>
    sendMatchMessage(matchId, 'Реванш!', kind: 'rematch');

/// Принимает реванш и возвращает id нового боя.
///
/// Матч создаёт сервер (RPC rematch_start): режим и языковую пару он
/// копирует из старого боя, поэтому реванш одинаково работает в Дуэли и в
/// Состязании. Соперник узнаёт о новом бое из того же чата — сообщением
/// 'rematch_started', которое пишет та же функция.
Future<String> acceptRematch(String matchId) async {
  final id = await supabase.rpc('rematch_start', params: {'p_match_id': matchId});
  return id as String;
}

/// Сообщение переписки с другом.
class DirectMessage {
  final String id;
  final String senderId;
  final String recipientId;
  final String body;
  final DateTime createdAt;

  const DirectMessage({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.body,
    required this.createdAt,
  });

  factory DirectMessage.fromRow(Map<String, dynamic> row) => DirectMessage(
        id: row['id'] as String,
        senderId: row['sender_id'] as String,
        recipientId: row['recipient_id'] as String,
        body: ((row['body'] as String?) ?? '').trim(),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  /// Собеседник в этой переписке — тот из двоих, кто не я.
  String otherSide(String myId) => senderId == myId ? recipientId : senderId;
}

/// Живая лента ВСЕЙ моей переписки, по возрастанию времени.
///
/// ПОЧЕМУ НЕ ПОТОК ОДНОГО ДИАЛОГА. Лента аватарок сверху чата двигается по
/// последнему сообщению любого из друзей, а переключение диалога не должно
/// пересоздавать подписку: на каждом нажатии это была бы новая сессия
/// Realtime. RLS и так отдаёт только мои строки — фильтр по собеседнику
/// дешевле сделать на месте.
Stream<List<DirectMessage>> directMessagesStream() => supabase
    .from('direct_messages')
    .stream(primaryKey: ['id'])
    .map((rows) => rows.map(DirectMessage.fromRow).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt)));

Future<void> sendDirectMessage(String friendId, String body) async {
  final text = body.trim();
  if (text.isEmpty) return;
  await supabase.from('direct_messages').insert({
    'sender_id': currentUserId,
    'recipient_id': friendId,
    'body': text.length > 1000 ? text.substring(0, 1000) : text,
  });
  // «Социальный» считает, скольким игрокам изучаемого языка игрок написал
  // первым. Считает по самой переписке (sync_social_achievement, миграция
  // 0051), поэтому сюда достаточно ткнуть после отправки — а не вести
  // отдельный счётчик, который пришлось бы чинить после каждого сбоя.
  unawaited(syncSocialAchievement());
}

/// Закреплённые собеседники — у каждого свои.
Future<Set<String>> loadChatPins() async {
  final rows = await supabase
      .from('friend_chat_pins')
      .select('friend_id')
      .eq('user_id', currentUserId);
  return {for (final row in rows) row['friend_id'] as String};
}

Future<void> setChatPin(String friendId, bool pinned) async {
  if (pinned) {
    await supabase.from('friend_chat_pins').upsert({
      'user_id': currentUserId,
      'friend_id': friendId,
    });
  } else {
    await supabase
        .from('friend_chat_pins')
        .delete()
        .eq('user_id', currentUserId)
        .eq('friend_id', friendId);
  }
}
