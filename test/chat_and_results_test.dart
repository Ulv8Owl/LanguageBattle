import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/widgets/round_review.dart';

/// Итоги матча, переписка и реванш.
///
/// Проверяется КОНТРАКТ, а не вёрстка: где что нарисовано, решает макет и
/// он меняется, а правила — кто кого видит, кто кому пишет и что означает
/// равный счёт — меняться молча не должны.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String results() => read('lib/features/battle/battle_results_screen.dart');
  String matchChat() => read('lib/widgets/match_chat_panel.dart');
  String friendsChat() => read('lib/features/friends/friends_chat_panel.dart');
  String friends() => read('lib/features/friends/friends_screen.dart');
  String migration() => read('supabase/migrations/0049_chats_and_rematch.sql');

  group('плашка ошибки', () {
    testWidgets('длинная цитата обрезается, а не вылезает за плашку', (tester) async {
      // Плашка — это цитата игрока, а она бывает в половину фразы. Целиком
      // её всё равно видно: в раскрытой плашке текст не обрезан.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: MistakeChip(
              text: 'я очень длинная цитата игрока, которая точно не помещается в строку',
              missed: true,
              onTap: () {},
            ),
          ),
        ),
      ));
      final text = tester.widget<Text>(find.textContaining('я очень длинная'));
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.maxLines, 1);
      // И плашка осталась внутри отведённой ширины.
      expect(tester.getSize(find.byType(MistakeChip)).width, lessThanOrEqualTo(200));
    });
  });

  group('итоги матча', () {
    test('равные баллы — ничья, и она белая', () {
      // Сервер выбирает победителя по выигранным раундам, и при равной
      // сумме баллов это назвало бы поражением ответ, который им не был.
      final s = results();
      expect(s, contains("win('ПОБЕДА', AppColors.gold)"));
      expect(s, contains("loss('ПОРАЖЕНИЕ', AppColors.danger)"));
      expect(s, contains("draw('НИЧЬЯ', AppColors.cream)"));
      expect(s, contains('} else if (myTotal > opponentTotal) {'));
      expect(s, contains('outcome = _Outcome.draw;'));
    });

    test('стороны не меняются местами, своя аватарка всегда золотая', () {
      // Свою аватарку игрок ищет глазами в одном и том же месте, а не там,
      // куда его поставил исход боя.
      final s = results();
      final board = s.substring(s.indexOf('class _ScoreBoard'));
      expect(board.indexOf('_face(opponentName'), lessThan(board.indexOf('_face(myName')));
      expect(board, contains('_face(myName, myAvatar, AppColors.gold'));
      // Своё число красится цветом исхода — тем же, что и слово наверху.
      expect(board, contains('color: myColor'));
      expect(s, contains('myColor: outcome.color'));
    });

    test('разбора соперника на итогах нет и не появляется', () {
      // Разбор — это готовый перевод фразы. На итогах он уже ничего не
      // решает, но привычка показывать чужой разбор не должна заводиться.
      final s = results();
      expect(s.contains('RoundReview'), isFalse);
      expect(s.contains('mistakesFrom'), isFalse);
    });
  });

  group('мини-чат и реванш', () {
    test('кнопка ответа только у вызванного и только до начала боя', () {
      final s = matchChat();
      expect(s, contains('m.isRematchOffer && m.userId != widget.myId'));
      expect(s, contains('canAnswerRematch = offeredByOpponent && started.isEmpty'));
      expect(s, contains("'Ответить на Реванш'"));
    });

    test('в новый бой уходят оба, и ровно один раз', () {
      final s = matchChat();
      // Принявший узнаёт id из ответа функции, звавший — из того же чата.
      expect(s, contains('widget.onRematchStarted(newId)'));
      expect(s, contains('_rematchHandled'));
      expect(results(), contains("context.go('/battle/\$newMatchId')"));
    });

    test('присутствие соперника настоящее, а не угаданное', () {
      // «Пока соперник здесь» — это Realtime presence. Угадывать его по
      // последнему сообщению значило бы обещать доставку тому, кто ушёл.
      final s = matchChat();
      expect(s, contains('onPresenceSync'));
      expect(s, contains('channel.track('));
      expect(s, contains('RealtimeChannelConfig(key: widget.myId)'));
    });

    test('реванш зовётся из карточки игрока', () {
      expect(results(), contains('onRematch: isMe ? null : _offerRematch'));
      final card = read('lib/features/battle/player_card_sheet.dart');
      expect(card, contains("label: const Text('Реванш')"));
      // Кнопки нет там, где её не передали, и нет в своей карточке.
      expect(card, contains('if (widget.onRematch != null)'));
      expect(card, contains('if (!widget.isMe)'));
    });
  });

  group('чат с друзьями', () {
    test('«Позвать» уехало в карточку, в строке — «Написать»', () {
      final s = friends();
      expect(s, contains("child: const Text('Написать',"));
      // В самой строке кнопки «Позвать» больше нет: она передаётся в
      // карточку игрока обработчиком.
      final row = s.substring(s.indexOf('_friends.map((f) => Padding'), s.indexOf('/// Панель «ГРУППА»'));
      expect(row.contains("Text('Позвать'"), isFalse);
      expect(row, contains('onInvite:'));
      expect(read('lib/features/battle/player_card_sheet.dart'),
          contains("label: const Text('Позвать')"));
    });

    test('чат — не раздел и не экран, а панель внутри «Друзей»', () {
      // Подробности раскладки и жеста — в friends_chat_panel_test.dart;
      // здесь закреплено само решение.
      final s = friends();
      expect(s, contains('PullHandle('));
      expect(s, contains('child: FriendsChatPanel('));
      // Пятой кнопки внизу не появилось, и отдельного экрана тоже.
      expect(read('lib/features/arena/arena_shell.dart').contains('FriendsChat'), isFalse);
      expect(s.contains('MaterialPageRoute'), isFalse);
    });

    test('лента собеседников: закреплённые слева, потом по последнему слову', () {
      final s = friendsChat();
      expect(s, contains('if (pinnedA != pinnedB) return pinnedA ? -1 : 1;'));
      expect(s, contains('return lastB.compareTo(lastA);'));
      // Выбранный диалог виден по золотой обводке.
      expect(s, contains('ringColor: isSelected ? AppColors.gold : AppColors.lineStrong'));
      // Аватарки в переписке открывают карточку игрока.
      expect(s, contains('_openCard(message.senderId, name, isMine)'));
    });

    test('одна подписка на всю переписку, а не по одной на диалог', () {
      // Переключение собеседника не должно пересоздавать сессию Realtime.
      final s = friendsChat();
      expect(s, contains('directMessagesStream().listen'));
      expect(s.contains('.eq(\'recipient_id\''), isFalse);
    });
  });

  group('правила доступа', () {
    test('в чат матча пишет только участник и только от себя', () {
      final s = migration();
      expect(s, contains('public.is_match_participant(match_id, auth.uid())'));
      expect(s, contains('user_id = auth.uid()'));
      // Служебное сообщение о начатом бое клиенту недоступно: в нём id
      // нового матча, и подделка увела бы соперника в чужой бой.
      expect(s, contains("and kind in ('text', 'rematch')"));
    });

    test('личные сообщения — только друзьям', () {
      final s = migration();
      expect(s, contains("f.status = 'accepted'"));
      expect(s, contains('sender_id = auth.uid()'));
      expect(s, contains('direct_messages_not_self'));
    });

    test('реванш проверяет вызов и не создаёт второй бой', () {
      final s = migration();
      expect(s, contains("raise exception 'no rematch offer'"));
      expect(s, contains('if v_new_id is not null then'));
      // Режим и пара копируются — поэтому реванш одинаков в Дуэли и в
      // Состязании.
      expect(s, contains('v_old.game_mode, v_old.language_pair'));
    });

    test('живая доставка включена — иначе это переписка с перезаходом', () {
      final s = migration();
      for (final table in ['match_chat_messages', 'direct_messages', 'friend_chat_pins']) {
        expect(s, contains("'$table'"), reason: table);
      }
      expect(s, contains('supabase_realtime'));
    });

    test('правила проверяются на настоящей базе, а не на словах', () {
      // Политика, которую никто не пробовал нарушить, — это намерение.
      expect(File('tools/check_chat_rules.sql').existsSync(), isTrue);
      expect(File('tools/check_chat_stub.sql').existsSync(), isTrue);
      final check = read('tools/check_chat_rules.sql');
      expect(check, contains('ПРОВАЛ: посторонний написал в чужой чат'));
      expect(check, contains('ПРОВАЛ: написал от лица соперника'));
      expect(check, contains('ПРОВАЛ: реванш начался без вызова'));
      expect(check, contains('ПРОВАЛ: написал не другу'));
    });
  });
}
