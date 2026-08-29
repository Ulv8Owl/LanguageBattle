import 'package:flutter_test/flutter_test.dart';
import 'package:language_battle/core/text_diff.dart';

String render(List<DiffPart> parts) => parts
    .map((p) => switch (p.kind) {
          DiffKind.same => p.text,
          DiffKind.wrong => '[-${p.text}]',
          DiffKind.missing => '[+${p.text}]',
        })
    .join(' ');

void main() {
  test('всё сказано верно — правок нет', () {
    final parts = diffWords('I read books', 'I read books');
    expect(parts.every((p) => p.kind == DiffKind.same), isTrue);
  });

  test('пунктуация и регистр не считаются правкой', () {
    final parts = diffWords('my sister, Usually. go to shop', 'My sister usually go to shop');
    expect(parts.every((p) => p.kind == DiffKind.same), isTrue,
        reason: render(parts));
  });

  test('неправильное слово помечается как ошибка, правильное подставляется', () {
    final parts = diffWords('My sister like read books', 'My sister likes to read books');
    expect(render(parts), 'My sister [-like] [+likes] [+to] read books');
  });

  test('пропущенные слова помечаются как пропуск', () {
    final parts = diffWords('I read books', 'I read books about science in her room');
    expect(render(parts), 'I read books [+about] [+science] [+in] [+her] [+room]');
  });

  test('переведена только половина фразы — весь хвост как пропуск', () {
    final parts = diffWords(
      'My sister likes to read books',
      'My sister likes to read books. After that she goes to the shop',
    );
    final missing = parts.where((p) => p.kind == DiffKind.missing).length;
    expect(missing, 7, reason: render(parts));
  });

  test('лишнее слово у игрока помечается как ошибка', () {
    final parts = diffWords('I really read books', 'I read books');
    expect(render(parts), 'I [-really] read books');
  });

  test('пустой исправленный вариант — сравнивать не с чем', () {
    final parts = diffWords('I read books', '');
    expect(parts.every((p) => p.kind == DiffKind.same), isTrue);
    expect(parts.length, 3);
  });

  test('самоисправление игрока не считается ошибкой', () {
    // Судья присылает cleaned без брошенного варианта, поэтому сравнение
    // идёт уже с ним — «go to magazine» в подсветке не участвует.
    final parts = diffWords('Go to shop', 'Go to the shop');
    expect(render(parts), 'Go to [+the] shop');
  });

  test('апостроф внутри слова сохраняется', () {
    final parts = diffWords('he dont like', "he doesn't like");
    expect(render(parts), "he [-dont] [+doesn't] like");
  });
}
