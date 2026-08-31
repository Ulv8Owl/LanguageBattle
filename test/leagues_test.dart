import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/core/leagues.dart';
import 'package:language_battle/core/word_packs.dart';

void main() {
  test('шесть лиг, по одной на уровень CEFR', () {
    expect(leagueBands.length, wordLevelSlugs.length);
    expect(
      leagueBands.map((b) => b.cefr.toLowerCase()).toList(),
      wordLevelSlugs,
      reason: 'порядок лиг должен совпадать с порядком банков слов и фраз',
    );
  });

  test('пороги идут подряд и без разрывов', () {
    for (var i = 1; i < leagueBands.length; i++) {
      expect(leagueBands[i].min, leagueBands[i - 1].max,
          reason: 'между лигами не должно быть дыр по рейтингу');
    }
  });

  test('рейтинг попадает в свою лигу и в свой индекс уровня', () {
    for (var i = 0; i < leagueBands.length; i++) {
      final band = leagueBands[i];
      final inside = band.min + 1;
      expect(leagueFor(inside).cefr, band.cefr);
      expect(leagueIndexForRating(inside), i,
          reason: 'по этому индексу берутся фразы и слова уровня');
    }
  });

  test('подпись под кубком называет и лигу, и уровень', () {
    expect(leagueBands.first.titleWithLevel, 'Олово — A1');
    expect(leagueBands.last.titleWithLevel, 'Алмаз — C2');
  });

  test('надпись на кубке контрастна его цвету', () {
    // Серебро почти белое, олово тёмно-зелёное — одним цветом текста не
    // обойтись, иначе на одном из кубков уровень будет нечитаем.
    for (final band in leagueBands) {
      final light = band.color.computeLuminance();
      final text = band.onColor.computeLuminance();
      expect((light - text).abs(), greaterThan(0.3), reason: band.name);
    }
  });
}
