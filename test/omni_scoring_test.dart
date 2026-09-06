import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/theme.dart';
import 'package:language_battle/widgets/correction_text.dart';

/// Балл считает программа по разбору модели, а подсветка красит ровно тот
/// же список кусков. Расхождение здесь означало бы, что игроку показывают
/// красным одно, а снимают баллы за другое, — и заметить это на глаз
/// невозможно.
void main() {
  group('подсветка несказанного', () {
    List<TextSpan> spans(String corrected, List<String> missing) =>
        missingSpans(corrected, missing);

    bool isRed(TextSpan s) => s.style?.color == AppColors.danger;

    test('красит ровно названные куски', () {
      final result = spans('My brother works in a big hotel', ['in a big hotel']);
      final red = result.where(isRed).map((s) => s.text).join();
      expect(red, 'in a big hotel');
      final plain = result.where((s) => !isRed(s)).map((s) => s.text).join();
      expect(plain, 'My brother works ');
    });

    test('регистр не мешает', () {
      // Модель цитирует свой же перевод, но заглавная буква в начале
      // предложения у неё гуляет. Терять из-за этого подсветку целого
      // куска нельзя.
      final red = spans('He starts work at six', ['he starts'])
          .where(isRed)
          .map((s) => s.text)
          .join();
      expect(red, 'He starts');
    });

    test('кусок, которого в переводе нет, ничего не красит', () {
      // Модель может процитировать неточно. Молчание тут лучше, чем
      // покрасить наугад не то место.
      final result = spans('He starts work at six', ['совсем другой текст']);
      expect(result.any(isRed), isFalse);
      expect(result.map((s) => s.text).join(), 'He starts work at six');
    });

    test('соседние символы склеены в один фрагмент', () {
      // Иначе на фразу из сорока символов вышло бы сорок TextSpan, и
      // перенос строк начал бы рваться в произвольных местах.
      expect(spans('abcdef', ['cd']).length, 3);
    });

    test('пустой перевод не роняет разметку', () {
      expect(spans('', ['что-нибудь']), isEmpty);
    });
  });

  group('формула балла', () {
    // Повторяет scoreFor из supabase/functions/_shared/omniJudge.ts.
    // Дублирование здесь осознанное: тесты Deno в этом проекте не
    // запускаются, а формула — то, что игрок увидит как «почему шесть», и
    // проверить её числами важнее, чем избежать копии.
    int score(String correct, List<String> missing, int errors) {
      final marked = List<bool>.filled(correct.length, false);
      final haystack = correct.toLowerCase();
      for (final raw in missing) {
        final needle = raw.trim().toLowerCase();
        if (needle.isEmpty) continue;
        var from = 0;
        while (true) {
          final at = haystack.indexOf(needle, from);
          if (at < 0) break;
          for (var i = at; i < at + needle.length && i < marked.length; i++) {
            marked[i] = true;
          }
          from = at + needle.length;
        }
      }
      final total = correct.replaceAll(RegExp(r'\s+'), ' ').trim().length;
      final share =
          total == 0 ? 0.0 : (marked.where((m) => m).length / total).clamp(0.0, 1.0);
      return (10 - (10 * share).round() - errors).clamp(1, 10);
    }

    test('сказал всё и без ошибок — десять', () {
      expect(score('He starts work at six', const [], 0), 10);
    });

    test('не сказал 60% — минус шесть', () {
      // Ровно пример из постановки задачи.
      const correct = '0123456789';
      expect(score(correct, const ['012345'], 0), 4);
    });

    test('каждая ошибка снимает по баллу', () {
      expect(score('He starts work at six', const [], 3), 7);
    });

    test('пропуски и ошибки складываются', () {
      const correct = '0123456789';
      expect(score(correct, const ['01234'], 2), 3);
    });

    test('ниже единицы не опускаемся', () {
      // Отрицательных баллов в игре нет: единица и есть «не получилось».
      expect(score('0123456789', const ['0123456789'], 5), 1);
    });

    test('повторная цитата не считается дважды', () {
      // Иначе доля потерянного превысила бы единицу, и игрок недосчитался
      // бы баллов за нашу арифметику, а не за свой ответ.
      //
      // Число закреплено явно, а не только равенством двух вызовов: сверка
      // с настоящей scoreFor (tools/check_score_formula.ts) сравнивает
      // именно значения, и «оба вернули одно и то же неверное» она бы не
      // поймала.
      const correct = 'aaaa bbbb';
      expect(score(correct, const ['aaaa'], 0), 6);
      expect(score(correct, const ['aaaa', 'aaaa'], 0), 6);
    });

    test('перевода нет — отвечают только ошибки', () {
      expect(score('', const ['что угодно'], 2), 8);
    });
  });
}
