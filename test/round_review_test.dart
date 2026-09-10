import 'dart:io';

import 'package:flutter/gestures.dart';
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
  ReviewSpan miss(String t, {String means = ''}) =>
      ReviewSpan(kind: 'miss', text: t, means: means);
  ReviewSpan bad(String t) => ReviewSpan(kind: 'bad', text: t);

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
      );

  group('RoundReview', () {
    testWidgets('показывает ленту разбора', (tester) async {
      await pump(
        tester,
        RoundReview(
          spans: [ok('I '), miss('walk there', means: 'хожу туда')],
          targetLanguage: 'en',
        ),
      );
      expect(find.text('Разбор:'), findsOneWidget);
    });

    testWidgets('серых подписей под лентой больше нет', (tester) async {
      // Плашка теперь — сам красный текст, а подписи говорили о ленте то,
      // что лента и так показывает.
      await pump(tester, RoundReview(spans: [ok('I walk there')], targetLanguage: 'en'));
      expect(find.text('Ошибок не найдено — сказано верно'), findsNothing);
      expect(find.textContaining('фраза сказана не целиком'), findsNothing);
      expect(find.textContaining('Нажми на кусок'), findsNothing);
    });

    testWidgets('нет ленты — нет и разбора', (tester) async {
      // Балл при этом показывается: за него отвечает не этот виджет.
      await pump(tester, const RoundReview(spans: [], targetLanguage: 'en'));
      expect(find.text('Разбор:'), findsNothing);
    });
  });

  group('перевод несказанного', () {
    test('читается из ленты полем m', () {
      final spans = ReviewSpan.fromJson([
        {'k': 'ok', 't': 'My phone is '},
        {'k': 'miss', 't': 'very ', 'm': 'очень'},
        {'k': 'bad', 't': 'because he '},
        {'k': 'miss', 't': 'so it is', 'm': 'поэтому он'},
      ]);
      expect(spans.length, 4);
      expect(spans[1].means, 'очень');
      expect(spans[1].hasMeaning, isTrue);
      // Перевод бывает только у несказанного: у своих слов игрока его нет.
      expect(spans[0].hasMeaning, isFalse);
      expect(spans[2].hasMeaning, isFalse);
    });

    test('нажимается только красное И только с переводом', () {
      // Красный кусок без перевода нажимать не на что, и обещать нажатие
      // подчёркиванием нельзя: игрок будет тыкать в пустоту.
      var asked = 0;
      final out = reviewSpans(
        [
          ok('My phone is '),
          miss('very ', means: 'очень'),
          bad('because he '),
          miss('so it is'),
        ],
        recognizerFor: (_) {
          asked++;
          return TapGestureRecognizer();
        },
      );
      expect(asked, 1, reason: 'распознаватель просят только у куска с переводом');
      final tappable = out.where((s) => s.recognizer != null).toList();
      expect(tappable.length, 1);
      expect(tappable.single.text, 'very ');
    });

    test('подряд идущее несказанное — один кусок, а не по слову', () {
      // Границы проводит дифф на сервере; здесь закреплено, что клиент их
      // не дробит: «so it is» — одна плашка, а не три.
      final spans = ReviewSpan.fromJson([
        {'k': 'miss', 't': 'so it is', 'm': 'поэтому он'},
      ]);
      expect(spans.single.text, 'so it is');
      final out = reviewSpans(spans, recognizerFor: (_) => TapGestureRecognizer());
      expect(out.length, 1);
    });
  });

  group('лента боя', () {
    final source = File('lib/features/battle/battle_screen.dart').readAsStringSync();

    test('бой показывает тот же разбор, а не свою копию', () {
      expect(source, contains('RoundReview('));
      expect(source, contains("import '../../widgets/round_review.dart';"));
    });

    test('разбор видит только его хозяин', () {
      // Объяснения написаны на родном языке хозяина — в Дуэли соперник
      // этого языка может не знать вовсе, а чужие ошибки ему и не нужны.
      final verdict = source.indexOf('items.add(_AiVerdict(');
      expect(verdict, greaterThan(0));
      final guard = source.lastIndexOf('if (!isMine) continue;', verdict);
      expect(guard, greaterThan(0), reason: 'перед вердиктом должен стоять отсев чужих записей');
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
