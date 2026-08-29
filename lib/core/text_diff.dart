/// Пословное сравнение сказанного с исправленным вариантом.
///
/// Нужно, чтобы игрок видел правку наглядно: где он сказал не то слово, а
/// где вообще пропустил слово. Списком объяснений это не заменяется — по
/// нему не видно, как должна звучать фраза целиком.
///
/// Сравнение идёт по НОРМАЛИЗОВАННЫМ словам (без пунктуации и регистра):
/// распознавание само расставляет точки и заглавные буквы там, где игрок
/// просто сделал паузу, и считать это правкой нельзя — судья их тоже
/// игнорирует.
library;

enum DiffKind {
  /// Слово сказано верно.
  same,

  /// Слово сказано неправильно — в исправленном варианте его нет.
  wrong,

  /// Слово пропущено — есть в исправленном варианте, но не было сказано.
  missing,
}

class DiffPart {
  final String text;
  final DiffKind kind;

  const DiffPart(this.text, this.kind);

  @override
  String toString() => '${kind.name}:$text';
}

String _normalize(String word) =>
    word.toLowerCase().replaceAll(RegExp(r'''[^\p{L}\p{N}']''', unicode: true), '');

List<String> _tokenize(String text) =>
    text.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).toList();

/// Разбор различий между [spoken] (что распознали) и [corrected] (как
/// должно быть). Возвращает исправленный текст по порядку, помечая каждое
/// слово: сказано верно, сказано неверно или пропущено.
///
/// Если [corrected] пуст — правки нет, весь текст помечается как верный:
/// это не значит «всё правильно», это значит «сравнивать не с чем», и
/// вызывающий код решает, показывать ли блок вообще.
List<DiffPart> diffWords(String spoken, String corrected) {
  final a = _tokenize(spoken);
  final b = _tokenize(corrected);
  if (b.isEmpty) return [for (final w in a) DiffPart(w, DiffKind.same)];

  final na = [for (final w in a) _normalize(w)];
  final nb = [for (final w in b) _normalize(w)];

  // Наибольшая общая подпоследовательность: слова, которые игрок сказал
  // верно и в верном порядке. Всё, что не попало в неё, — либо лишнее/
  // неправильное у игрока, либо пропущенное им.
  final lcs = List.generate(na.length + 1, (_) => List<int>.filled(nb.length + 1, 0));
  for (var i = na.length - 1; i >= 0; i--) {
    for (var j = nb.length - 1; j >= 0; j--) {
      lcs[i][j] = na[i] == nb[j] ? lcs[i + 1][j + 1] + 1 : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final parts = <DiffPart>[];
  var i = 0;
  var j = 0;
  while (i < na.length && j < nb.length) {
    if (na[i] == nb[j]) {
      parts.add(DiffPart(b[j], DiffKind.same));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      parts.add(DiffPart(a[i], DiffKind.wrong));
      i++;
    } else {
      parts.add(DiffPart(b[j], DiffKind.missing));
      j++;
    }
  }
  while (i < na.length) {
    parts.add(DiffPart(a[i], DiffKind.wrong));
    i++;
  }
  while (j < nb.length) {
    parts.add(DiffPart(b[j], DiffKind.missing));
    j++;
  }
  return parts;
}
