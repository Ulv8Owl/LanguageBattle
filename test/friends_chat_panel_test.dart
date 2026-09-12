import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/widgets/chat_drawer.dart';

/// Выдвижной чат в разделе «Друзья».
///
/// Проверяется то, из-за чего его переделывали: он часть раздела и накрывает
/// его, а не раздвигает; полоска и окно — один предмет; жест работает и
/// пальцем, и нажатием.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String friends() => read('lib/features/friends/friends_screen.dart');
  String panel() => read('lib/features/friends/friends_chat_panel.dart');
  String drawer() => read('lib/widgets/chat_drawer.dart');

  Widget host({
    required double openness,
    VoidCallback? onTap,
    ValueChanged<double>? onDrag,
    ValueChanged<double>? onSettle,
    double height = 600,
  }) =>
      MaterialApp(
        home: Scaffold(
          // Stack — как в самом разделе: он даёт шторке СВОБОДНЫЕ
          // ограничения, и она сама решает свою высоту. Жёсткая рамка
          // (SizedBox вокруг) растянула бы её на всю высоту всегда.
          body: SizedBox(
            height: height,
            child: Stack(children: [
              ChatDrawer(
              openness: openness,
              maxBodyHeight: height - chatDrawerCollapsedHeight,
              onTap: onTap ?? () {},
              onDrag: onDrag ?? (_) {},
              onSettle: onSettle ?? (_) {},
                child: const ColoredBox(color: Colors.black, child: Text('чат')),
              ),
            ]),
          ),
        ),
      );

  group('шторка', () {
    testWidgets('свёрнутая — это ровно полоска, во всю ширину раздела',
        (tester) async {
      await tester.pumpWidget(host(openness: 0));
      final size = tester.getSize(find.byType(ChatDrawer));
      expect(size.height, chatDrawerCollapsedHeight);
      // Шторка — продолжение плашек под ней, а не всплывающее окно: ширина
      // та же, что у раздела.
      expect(size.width, tester.getSize(find.byType(Stack).first).width);
    });

    testWidgets('раскрытая занимает всю доступную высоту', (tester) async {
      await tester.pumpWidget(host(openness: 1));
      expect(tester.getSize(find.byType(ChatDrawer)).height, 600);
    });

    testWidgets('на полпути — полоска плюс половина окна', (tester) async {
      await tester.pumpWidget(host(openness: 0.5));
      final body = (600 - chatDrawerCollapsedHeight) / 2;
      expect(tester.getSize(find.byType(ChatDrawer)).height,
          closeTo(chatDrawerCollapsedHeight + body, 0.01));
    });

    testWidgets('одиночное нажатие переключает', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(openness: 0, onTap: () => taps++));
      await tester.tap(find.byType(ChatDrawer));
      expect(taps, 1);
    });

    testWidgets('шторка идёт за пальцем, а не прыгает', (tester) async {
      // Жест, который срабатывает только по отпусканию, — это длинное
      // нажатие, а не перетаскивание.
      final moves = <double>[];
      double? settled;
      await tester.pumpWidget(host(
        openness: 0,
        onDrag: moves.add,
        onSettle: (v) => settled = v,
      ));
      await tester.drag(find.byType(ChatDrawer), const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(moves, isNotEmpty);
      // Первые пиксели съедает порог распознавания жеста — это система, а
      // не мы; важно, что дальше шторка идёт за пальцем и вниз.
      final travelled = moves.reduce((a, b) => a + b);
      expect(travelled, greaterThan(60));
      expect(travelled, lessThanOrEqualTo(120));
      expect(settled, isNotNull);
    });

    test('полоска и окно — ОДИН предмет', () {
      // Две вложенные рамки выдавали бы их за два: раньше полоска была
      // отдельной плашкой и тянула за собой вторую.
      final s = drawer();
      expect('Border.all'.allMatches(s).length, 1);
      expect(s, contains('borderRadius: BorderRadius.circular(16)'));
      // Само окно своей рамки не рисует: его build отдаёт содержимое
      // сразу, без обёртки-контейнера.
      final p = panel();
      final build = p.substring(p.indexOf('  Widget build(BuildContext context) {'));
      expect(build.substring(0, build.indexOf('return ')), contains('ни своей рамки'));
      expect(build, contains('return _loading'));
    });

    test('окно не пересобирается на каждом кадре перетаскивания', () {
      // Иначе палец тащил бы не шторку, а перекладку всего чата.
      expect(drawer(), contains('OverflowBox('));
      expect(drawer(), contains('minHeight: maxBodyHeight'));
    });
  });

  group('раздел', () {
    test('шторка накрывает содержимое, а не раздвигает его', () {
      final s = friends();
      // Stack, а не Column: в Column вкладки уезжали бы вниз на каждый
      // пиксель перетаскивания.
      final build = s.substring(s.indexOf('Widget build(BuildContext context) {'));
      expect(build.indexOf('Stack('), lessThan(build.indexOf('ChatDrawer(')));
      // Место под свёрнутую полоску — НАД вкладками.
      expect(s, contains('const SizedBox(height: chatDrawerCollapsedHeight + 10),'));
      final column = build.indexOf('ChTabBar(');
      expect(build.indexOf('chatDrawerCollapsedHeight + 10'), lessThan(column));
    });

    test('чат один на три вкладки и живёт в разделе', () {
      final s = friends();
      // Владеет шторкой раздел, вкладка только просит открыть.
      expect(s, contains('class _FriendsScreenState extends State<FriendsScreen>'));
      expect(s, contains('_FriendsListTab(onWrite: _openChat)'));
      expect(s, contains('final void Function(String friendId) onWrite;'));
      // Ни экрана, ни маршрута.
      expect(s.contains('MaterialPageRoute'), isFalse);
      expect(read('lib/core/router.dart').contains('FriendsChat'), isFalse);
    });

    test('панель всегда в дереве — переписка грузится с разделом', () {
      expect(friends(), contains('child: FriendsChatPanel('));
      expect(friends().contains('if (_chatOpen) FriendsChatPanel'), isFalse);
      expect(panel().contains('Scaffold('), isFalse);
    });

    test('протяжка вниз при открытой клавиатуре убирает клавиатуру', () {
      // Низ экрана занят самой клавиатурой, и эта полоска — единственное
      // свободное место, за которое её можно убрать.
      final s = friends();
      expect(s, contains('if (dy > 0 && MediaQuery.viewInsetsOf(context).bottom > 0) {'));
      expect(s, contains('FocusScope.of(context).unfocus();'));
    });

    test('бросок решает сильнее места, где отпустили', () {
      final s = friends();
      expect(s, contains('if (velocity > 200) {'));
      expect(s, contains('} else if (velocity < -200) {'));
      expect(s, contains('} else if (_chat.value > 0.5) {'));
    });
  });

  group('лента собеседников', () {
    test('без свечения, по центру, повторный тап открывает профиль', () {
      final s = panel();
      expect(s, contains('glow: false'));
      expect(s, contains('mainAxisAlignment: MainAxisAlignment.center'));
      expect(s, contains('onTap: () => isSelected'));
      expect(s, contains('? _openCard(f.id, f.username, false)'));
      // Высота ленты считается от размера аватарки, а не задана на глаз.
      expect(s, contains('height: avatarSize + 22'));
    });
  });
}
