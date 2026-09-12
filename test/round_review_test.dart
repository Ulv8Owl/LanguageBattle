import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/widgets/correction_text.dart';
import 'package:language_battle/widgets/round_review.dart';

/// Разбор ответа один на все три режима.
///
/// Раньше он жил только в Одиночной Игре, а в бою показывался балл и голая
/// строка. Две копии одного разбора неминуемо разъезжаются, поэтому здесь
/// проверяется и сам виджет, и то, что бой зовёт именно его — и показывает
/// только своему хозяину.
void main() {
  ReviewSpan ok(String t) => ReviewSpan(kind: 'ok', text: t);
  ReviewSpan miss(String t) => ReviewSpan(kind: 'miss', text: t);

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
      );

  group('RoundReview', () {
    testWidgets('показывает ленту разбора и плашки ошибок', (tester) async {
      await pump(
        tester,
        RoundReview(
          spans: [ok('I '), miss('walk there')],
          mistakes: const [
            Mistake(span: 'I go', message: 'После go нужен предлог', correction: 'I walk'),
          ],
          targetLanguage: 'en',
        ),
      );

      expect(find.text('Разбор:'), findsOneWidget);
      expect(find.text('I go'), findsOneWidget);
    });

    testWidgets('без ошибок — только лента, без серой подписи', (tester) async {
      // Строка «Ошибок не найдено — сказано верно» отсюда убрана: она
      // повторяла заголовок над разбором и балл рядом, а в ленте и так
      // видно, что красного в ней нет.
      await pump(
        tester,
        RoundReview(spans: [ok('I walk there')], mistakes: const [], targetLanguage: 'en'),
      );
      expect(find.text('Разбор:'), findsOneWidget);
      expect(find.textContaining('Ошибок не найдено'), findsNothing);
      expect(find.byType(MistakeBreakdown), findsNothing);
    });

    testWidgets('недоговорённую фразу не подписываем ничем', (tester) async {
      // Игрок сказал одно предложение из двух без единой ошибки в
      // сказанном — и видел «Ошибок не найдено» над красным пропуском и
      // сниженным баллом. Обе подписи убраны: непроизнесённое видно в
      // ленте красным, а неполноту ответа называет балл.
      await pump(
        tester,
        RoundReview(
          spans: [ok('I walk there. '), miss('Then I go home.')],
          mistakes: const [],
          targetLanguage: 'en',
        ),
      );
      expect(find.text('Ошибок не найдено — сказано верно'), findsNothing);
      expect(find.textContaining('фраза сказана не целиком'), findsNothing);
      // Само несказанное при этом на экране есть.
      expect(find.textContaining('Then I go home.'), findsOneWidget);
    });

    testWidgets('нет ленты — нет и разбора', (tester) async {
      // Балл при этом показывается: за него отвечает не этот виджет.
      await pump(
        tester,
        const RoundReview(spans: [], mistakes: [], targetLanguage: 'en'),
      );
      expect(find.byType(MistakeBreakdown), findsNothing);
      expect(find.text('Разбор:'), findsNothing);
    });
  });

  group('mistakesFrom', () {
    test('берёт только ошибки судьи и только заполненные', () {
      final out = mistakesFrom([
        {'category': 'omni', 'span_text': 'I go', 'message': 'нужен другой глагол', 'replacement': 'I walk'},
        // Без объяснения плашка обещает разбор, которого нет.
        {'category': 'omni', 'span_text': 'a', 'message': '  ', 'replacement': ''},
        // Без фрагмента её не к чему привязать.
        {'category': 'omni', 'span_text': '', 'message': 'что-то не так', 'replacement': ''},
        // Чужая категория — не наш разбор.
        {'category': 'legacy', 'span_text': 'b', 'message': 'старое', 'replacement': ''},
      ]);
      expect(out.map((m) => m.span), ['I go']);
      expect(out.single.correction, 'I walk');
    });
  });

  group('лента боя', () {
    final source = File('lib/features/battle/battle_screen.dart').readAsStringSync();

    test('бой показывает тот же разбор, а не свою копию', () {
      expect(source, contains('RoundReview('));
      expect(source, contains("import '../../widgets/round_review.dart';"));
    });

    test('разбор видит только его хозяин, а балл — оба', () {
      // Объяснения написаны на родном языке хозяина — в Дуэли соперник
      // этого языка может не знать вовсе, а чужие ошибки ему и не нужны.
      final verdict = source.indexOf('items.add(_AiVerdict(');
      expect(verdict, greaterThan(0));
      final guard = source.lastIndexOf('if (!isMine) {', verdict);
      expect(guard, greaterThan(0), reason: 'перед вердиктом должен стоять отсев чужих записей');
      // Но БАЛЛ соперника показывается: без него раунд выигрывался и
      // проигрывался молча — своя оценка видна, чужая нет.
      expect(source.substring(guard, verdict), contains('_OpponentScore('));
      // И ничего из разбора при этом не уезжает: у чужого балла нет ни
      // ленты, ни плашек.
      final opponentScore = source.indexOf('class _OpponentScore');
      expect(opponentScore, greaterThan(0));
      final body = source.substring(opponentScore, source.indexOf('class _SkippedTurn'));
      expect(body.contains('RoundReview'), isFalse);
      expect(body.contains('mistakes'), isFalse);
    });

    test('чужое голосовое закрыто, пока сам не ответил', () {
      // Чужой ответ — готовый перевод той же фразы. Послушав его первым,
      // игрок переводил бы не задание, а речь соперника.
      expect(source, contains("final iAnswered = _recordingFor(round.id, _myId, 'target') != null;"));
      expect(source, contains('lockedReason: isMine || iAnswered'));
      expect(source, contains('Вы не можете прослушать чужой ответ пока сами'));
      // Запрет держит сам виджет: кнопка гаснет и отвечает объяснением, а
      // не пропадает — пропавшее сообщение выглядело бы как сбой.
      final bubble = File('lib/widgets/voice_message_bubble.dart').readAsStringSync();
      expect(bubble, contains('final locked = widget.lockedReason;'));
      expect(bubble, contains('if (locked != null) {'));
    });

    test('пропущенный ход виден в ленте, а не превращается в пустоту', () {
      // Балл за пропуск сервер уже выставил, а голосового нет вовсе:
      // раньше на месте ответа не было ничего, и выигранный по чужому
      // молчанию раунд выглядел как ещё не доигранный.
      expect(source, contains('class _SkippedTurn'));
      expect(source, contains("'Пропуск хода'"));
      // Признак структурный: балл есть, записи нет.
      expect(source, contains("if (_recordingFor(round.id, userId, 'target') != null) continue;"));
      expect(source, contains('if (_scoreFor(round.id, userId) == null) continue;'));
    });

    test('после «прочитай на своём языке» хамелеон молчит', () {
      // Единственная реплика после перевода — приглашение прочитать текст
      // на родном. Дальше до самого разбора лента принадлежит игрокам.
      final notes = RegExp(r'_AiNote\(').allMatches(source).length;
      expect(notes, 2, reason: 'объявление класса и ровно одна реплика в ленте');
      expect(source, contains('Прочитай ещё раз текст, но уже на своём языке'));
      expect(source, isNot(contains('Запись голоса носителя')));
    });
  });
}
