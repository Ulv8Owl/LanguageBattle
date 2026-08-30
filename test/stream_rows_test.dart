import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/stream_rows.dart';

/// В ленте боя раунд рисовался дважды: снимок стрима содержал одну и ту же
/// строку два раза. Заметно это было и по мелочи — подпись «Скажи это
/// по-английски» показывается только у ТЕКУЩЕГО раунда, а висела у обоих,
/// потому что оба сравнения шли с одним и тем же id.
void main() {
  test('повтор одной строки схлопывается', () {
    final rows = dedupeById([
      {'id': 'r1', 'round_number': 1},
      {'id': 'r1', 'round_number': 1},
    ]);
    expect(rows.length, 1);
  });

  test('разные строки остаются все', () {
    final rows = dedupeById([
      {'id': 'r1', 'round_number': 1},
      {'id': 'r2', 'round_number': 2},
    ]);
    expect(rows.length, 2);
  });

  test('из повторов остаётся последняя версия строки', () {
    // Дубликат — это обычно та же строка после UPDATE: побеждать должна
    // свежая, иначе на экране останется устаревшее состояние.
    final rows = dedupeById([
      {'id': 'r1', 'generated_phrase': 'старое'},
      {'id': 'r1', 'generated_phrase': 'новое'},
    ]);
    expect(rows.single['generated_phrase'], 'новое');
  });

  test('после схлопывания порядок задаётся сортировкой, а не стримом', () {
    // .order() у стрима сортирует ПО УБЫВАНИЮ (ascending по умолчанию
    // false) — из-за этого новые сообщения уезжали вверх ленты.
    final rows = dedupeById([
      {'id': 'r2', 'round_number': 2},
      {'id': 'r1', 'round_number': 1},
    ])..sort((a, b) => (a['round_number'] as int).compareTo(b['round_number'] as int));
    expect(rows.map((r) => r['round_number']).toList(), [1, 2]);
  });

  test('пустой список остаётся пустым', () {
    expect(dedupeById([]), isEmpty);
  });
}
