import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/data/avatar_parts.dart';
import 'package:language_battle/widgets/chrolingo_widgets.dart';
import 'package:language_battle/widgets/correction_text.dart';

/// Аватар собирается стопкой спрайтов, и это его главное свойство: слои
/// одного размера уже совмещены художником, поэтому в коде нет ни одной
/// координаты. Сдвинуть деталь можно только в самом спрайте.
void main() {
  group('каталог частей', () {
    test('каждый слой действительно лежит в assets', () {
      // Опечатка в имени файла превращается в пустой слой, и заметить её
      // можно было бы только глазами на живом устройстве.
      final files = <String>{avatarBackground};
      for (final slot in avatarSlots) {
        for (final part in slot.parts) {
          files.addAll(part.layers);
        }
      }
      for (final path in files) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    });

    test('спрайты объявлены в pubspec, иначе их не будет в сборке', () {
      expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/avatar/'));
    });

    test('порядок слотов — он же порядок отрисовки', () {
      // Лицо поверх тела, глаза поверх лица. Перепутать эти два списка
      // нельзя: список слотов один.
      expect(avatarSlots.map((s) => s.id).toList(),
          ['body', 'face', 'brows', 'eyes', 'nose', 'lips']);
      final layers = avatarLayers(defaultAvatar());
      expect(layers.first, avatarBackground);
      expect(layers.indexOf('assets/avatar/Face1.png'),
          greaterThan(layers.indexOf('assets/avatar/Male-Brest.png')));
      expect(layers.indexOf('assets/avatar/eyes-1.png'),
          greaterThan(layers.indexOf('assets/avatar/Face1.png')));
    });

    test('обязательные части есть в наборе по умолчанию', () {
      final byDefault = defaultAvatar();
      for (final slot in avatarSlots.where((s) => !s.optional)) {
        expect(byDefault[slot.id], isNotNull, reason: slot.id);
      }
      expect(hasAvatar(byDefault), isTrue);
    });

    test('вариант из прошлой версии не роняет аватар', () {
      // Набор спрайтов растёт и меняется, а в базе у игрока может лежать
      // то, чего уже нет. Аватар — украшение, падать из-за него нельзя.
      expect(avatarLayers({'eyes': 'нет-такого', 'нет-такого-слота': 'x'}),
          [avatarBackground]);
      expect(hasAvatar({'eyes': 'нет-такого'}), isFalse);
    });

    test('из базы берутся только строки', () {
      expect(avatarFromJson({'eyes': 'eyes1', 'brows': 7, 3: 'x'}), {'eyes': 'eyes1'});
      expect(avatarFromJson(null), <String, String>{});
    });
  });

  group('кружок игрока', () {
    testWidgets('без собранного аватара — прежний инициал', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ChAvatar(name: 'Дима')),
      ));
      expect(find.text('Д'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('портрет занимает круг целиком, рамка его не ужимает', (tester) async {
      // Рамка в BoxDecoration создаёт отступ: картинка ужималась на её
      // толщину, и между портретом и кольцом оставалась полоска подложки —
      // те самые полоски по краям аватара.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(child: ChAvatar(name: 'Дима', avatar: defaultAvatar(), size: 100)),
        ),
      ));
      final image = tester.getSize(find.byType(Image).first);
      expect(image, const Size(100, 100));
    });

    testWidgets('с аватаром — слои вместо буквы', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChAvatar(name: 'Дима', avatar: defaultAvatar())),
      ));
      expect(find.text('Д'), findsNothing);
      expect(find.byType(Image), findsWidgets);
    });
  });

  group('зачёркивание в разборе', () {
    List<TextSpan> spansFor(String text) =>
        reviewSpans([ReviewSpan(kind: 'bad', text: text)]);

    test('пробел на стыке не зачёркнут', () {
      // Линия тянулась из неверного слова в следующее, правильное, и
      // выглядело это так, будто убрать надо оба.
      final out = spansFor('I go ');
      expect(out.map((s) => s.text).join(), 'I go ');
      final struck = out.where((s) => s.style?.decoration == TextDecoration.lineThrough);
      expect(struck.map((s) => s.text).join(), 'I go');
    });

    test('линия толстая — иначе её почти не видно', () {
      final struck = spansFor('I go').first;
      expect(struck.style?.decorationThickness, greaterThanOrEqualTo(3));
    });

    test('верное и несказанное не трогаем', () {
      final out = reviewSpans([
        ReviewSpan(kind: 'ok', text: 'I '),
        ReviewSpan(kind: 'miss', text: 'walk'),
      ]);
      expect(out.map((s) => s.text).join(), 'I walk');
      expect(out.every((s) => s.style?.decoration != TextDecoration.lineThrough), isTrue);
    });

    test('красное не подчёркивается', () {
      // Линия под красным делала из разбора ссылку и спорила с
      // зачёркиванием соседнего слова: две разные линии в одном месте.
      final out = reviewSpans([
        ReviewSpan(kind: 'miss', text: 'walk in', means: 'гуляем'),
      ]);
      expect(out.single.style?.decoration, isNot(TextDecoration.underline));
    });

    test('зачёркнутое нажимается вместе со своим исправлением', () {
      // Игрок видит ОДНО красное место — своё слово и верное рядом — и
      // попадает пальцем в любую половину. Нажималась только вторая, и
      // выглядело это как «иногда работает, иногда нет».
      final fix = ReviewSpan(kind: 'miss', text: 'sleeps a lot', means: 'много спит');
      final asked = <ReviewSpan>[];
      final out = reviewSpans(
        [ReviewSpan(kind: 'bad', text: 'many sleep '), fix],
        recognizerFor: (span) {
          asked.add(span);
          return TapGestureRecognizer();
        },
      );
      // Нажатий два — на зачёркнутом и на исправлении, — но перевод у них
      // ОДИН И ТОТ ЖЕ: у слова игрока своего перевода нет и быть не может.
      expect(asked.length, 2);
      expect(asked.every((s) => identical(s, fix)), isTrue);
      final struck = out.firstWhere((s) => s.style?.decoration == TextDecoration.lineThrough);
      expect(struck.recognizer, isNotNull);
    });

    test('лишнее слово игрока нажимать не на что', () {
      // Рядом нет исправления — значит он сказал лишнее, и переводить
      // нечего. Пустая плашка хуже её отсутствия.
      final out = reviewSpans(
        [ReviewSpan(kind: 'ok', text: 'I '), ReviewSpan(kind: 'bad', text: 'really')],
        recognizerFor: (span) => TapGestureRecognizer(),
      );
      expect(out.every((s) => s.recognizer == null), isTrue);
    });
  });

  group('редактор открывается только со своего аватара', () {
    String read(String path) => File(path).readAsStringSync();

    test('отдельной кнопки редактора больше нет', () {
      // Собранный портрет и есть то, на что хочется нажать, а иконка рядом
      // только спрашивала «а это тогда что?».
      final profile = read('lib/features/profile/profile_screen.dart');
      expect(profile.contains("tooltip: 'Редактор аватара'"), isFalse);
      expect(profile, contains('AvatarButton('));
      expect(read('lib/features/arena/arena_screen.dart'), contains('AvatarButton('));
    });

    test('в Профиле и на Арене аватар одного размера', () {
      // Это одно и то же лицо, и разный размер читался бы как разные вещи.
      final widget = read('lib/widgets/avatar_portrait.dart');
      expect(widget, contains('const double profileAvatarSize = 75;'));
      // Размер задаётся константой, а не числом на каждом экране.
      expect(read('lib/features/arena/arena_screen.dart').contains('size: 40,\n                ringColor'),
          isFalse);
    });

    test('чужой аватар редактор не открывает', () {
      // Кнопкой стал только свой кружок; в бою и в друзьях он остаётся
      // обычной картинкой.
      for (final path in [
        'lib/features/battle/battle_screen.dart',
        'lib/features/friends/friends_screen.dart',
        'lib/features/matchmaking/matchmaking_screen.dart',
      ]) {
        expect(read(path).contains('AvatarButton('), isFalse, reason: path);
      }
    });
  });

  test('аватары соперников подгружаются вместе с именами', () {
    String read(String path) => File(path).readAsStringSync();
    // Без equipped_avatar в запросе у всех соперников остались бы буквы.
    for (final path in [
      'lib/features/battle/battle_screen.dart',
      'lib/features/friends/friends_screen.dart',
      'lib/features/matchmaking/matchmaking_screen.dart',
      'lib/features/battle/player_card_sheet.dart',
    ]) {
      expect(read(path), contains('equipped_avatar'), reason: path);
    }
  });
}
