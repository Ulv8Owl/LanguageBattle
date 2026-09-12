import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/widgets/pull_handle.dart';

/// Выдвижной чат в разделе «Друзья».
///
/// Проверяется то, из-за чего чат переделывали: он часть раздела, а не
/// отдельный экран, и полоска работает и пальцем, и нажатием.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String friends() => read('lib/features/friends/friends_screen.dart');
  String panel() => read('lib/features/friends/friends_chat_panel.dart');

  group('полоска', () {
    testWidgets('одиночное нажатие переключает', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PullHandle(
            onTap: () => taps++,
            onDrag: (_) {},
            onSettle: (_) {},
          ),
        ),
      ));
      await tester.tap(find.byType(PullHandle));
      expect(taps, 1);
    });

    testWidgets('панель идёт за пальцем, а не прыгает', (tester) async {
      // Жест, который срабатывает только по отпусканию, — это длинное
      // нажатие, а не перетаскивание.
      final moves = <double>[];
      double? settled;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PullHandle(
            onTap: () {},
            onDrag: moves.add,
            onSettle: (v) => settled = v,
          ),
        ),
      ));
      await tester.drag(find.byType(PullHandle), const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(moves, isNotEmpty);
      // Первые пиксели съедает порог распознавания жеста — это система, а
      // не мы; важно, что дальше панель идёт за пальцем и вниз.
      final travelled = moves.reduce((a, b) => a + b);
      expect(travelled, greaterThan(60));
      expect(travelled, lessThanOrEqualTo(120));
      expect(settled, isNotNull);
    });

    testWidgets('высота ручки совпадает с той, что вычитает раздел', (tester) async {
      // Разойдутся — раскрытый чат либо не достанет до низа, либо уедет
      // под нижнюю панель приложения.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            PullHandle(onTap: () {}, onDrag: (_) {}, onSettle: (_) {}),
          ]),
        ),
      ));
      expect(tester.getSize(find.byType(PullHandle)).height, pullHandleHeight);
    });

    test('выглядит как в макете: жёлтая полоска в тёмной плашке', () {
      final s = read('lib/widgets/pull_handle.dart');
      expect(s, contains('color: AppColors.gold'));
      expect(s, contains('width: 74'));
      // Без подписи: в макете её нет.
      expect(s.contains("'сообщения'"), isFalse);
    });
  });

  group('раскладка раздела', () {
    testWidgets('свёрнутая панель занимает ноль, а список — всё остальное',
        (tester) async {
      // Та же раскладка, что в разделе: панель полной высоты, обрезанная
      // Align'ом по доле раскрытия. При доле 0 список получает всё, при
      // доле 1 — ничего, и ноль высоты его не ломает.
      Widget layout(double factor) => MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 600,
                child: LayoutBuilder(
                  builder: (context, c) {
                    final maxChat = c.maxHeight - pullHandleHeight;
                    return Column(children: [
                      ClipRect(
                        child: Align(
                          alignment: Alignment.topCenter,
                          heightFactor: factor,
                          child: SizedBox(
                            height: maxChat,
                            child: const ColoredBox(color: Colors.black),
                          ),
                        ),
                      ),
                      PullHandle(onTap: () {}, onDrag: (_) {}, onSettle: (_) {}),
                      Expanded(
                        child: ClipRect(
                          child: RefreshIndicator(
                            onRefresh: () async {},
                            child: ListView(
                              children: const [SizedBox(height: 80, child: Text('друг'))],
                            ),
                          ),
                        ),
                      ),
                    ]);
                  },
                ),
              ),
            ),
          );

      await tester.pumpWidget(layout(0));
      expect(tester.getSize(find.byType(ListView)).height, 600 - pullHandleHeight);

      await tester.pumpWidget(layout(1));
      await tester.pump();
      expect(tester.getSize(find.byType(ListView)).height, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('чат — часть раздела, а не экран', () {
    test('панель не открывается маршрутом и не носит Scaffold', () {
      final s = panel();
      expect(s, contains('class FriendsChatPanel'));
      expect(s.contains('Scaffold('), isFalse);
      expect(s.contains('AppBar('), isFalse);
      // Никакого push: раздел не покидается.
      expect(friends().contains('MaterialPageRoute'), isFalse);
      expect(read('lib/core/router.dart').contains('FriendsChat'), isFalse);
    });

    test('панель в дереве всегда — переписка грузится с разделом', () {
      final s = friends();
      expect(s, contains('heightFactor: _chat.value'));
      expect(s, contains('child: FriendsChatPanel('));
      // Свёрнутость — это доля, а не «показать/спрятать»: панель с нулевой
      // высотой остаётся смонтированной и уже подписана на сообщения.
      expect(s.contains('if (_chatOpen) FriendsChatPanel'), isFalse);
    });

    test('«Написать» раскрывает панель и выбирает собеседника', () {
      final s = friends();
      expect(s, contains('onPressed: () => _openChat(f.id)'));
      expect(s, contains('_chat.animateTo(1, curve: Curves.easeOut);'));
      expect(s, contains('if (friendId != null) _chatWith = friendId;'));
    });

    test('бросок решает сильнее места, где отпустили', () {
      // Короткий резкий свайп должен срабатывать, даже если панель
      // отъехала на четверть.
      final s = friends();
      expect(s, contains('if (velocity > 200) {'));
      expect(s, contains('} else if (velocity < -200) {'));
      expect(s, contains('} else if (_chat.value > 0.5) {'));
    });
  });
}
