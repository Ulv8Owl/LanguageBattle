import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:language_battle/data/achievements.dart';
import 'package:language_battle/data/phrase_glossary.dart';

/// Тренировка, достижения и снятый лимит раундов.
///
/// Проверяется КОНТРАКТ: правила, из-за которых экраны выглядят так, а не
/// иначе. Расстановка виджетов — дело макета и меняется; правило «меньше
/// десяти слов до карточек не пускаем» меняться молча не должно.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String training() => read('lib/features/flashcards/flashcards_screen.dart');
  String solo() => read('lib/features/training/training_screen.dart');
  String profile() => read('lib/features/profile/profile_screen.dart');

  group('глоссарий', () {
    test('слово режется так же, как в сборщике', () {
      // У Python «\w» с UNICODE знает про кириллицу, у Dart — навсегда нет,
      // поэтому выражения записаны по-разному и совпадать обязаны РЕЗУЛЬТАТОМ.
      List<String> cut(String text) =>
          PhraseGlossary.wordPattern.allMatches(text).map((m) => m[0]!).toList();
      expect(cut('Я встаю'), ['Я', 'встаю']);
      expect(cut('в семь'), ['в', 'семь']);
      expect(cut("I don't like"), ['I', "don't", 'like']);
      expect(cut('todas las mañanas'), ['todas', 'las', 'mañanas']);
      // Знаки препинания словами не считаются и в карточку не попадают.
      expect(cut('кофе, чай.'), ['кофе', 'чай']);
    });

    test('расхождение нарезок не подставляет чужой перевод', () {
      // Если файл разойдётся с фразами, слово получит перевод элемента, а
      // не перевод соседнего слова: чужому переводу поверят.
      final words = PhraseGlossary.wordsOf(
        level: 0,
        native: 'ru',
        target: 'en',
        phraseInLevel: 0,
        elementIndex: 0,
        nativeElement: 'совсем другой элемент',
        targetElement: 'a completely different one',
      );
      expect(words.map((w) => w.word), ['совсем', 'другой', 'элемент']);
      expect(words.every((w) => w.translation == 'a completely different one'), isTrue);
    });

    test('A1 собран для всех шести пар', () {
      for (final pair in ['ru-en', 'ru-es', 'en-ru', 'en-es', 'es-ru', 'es-en']) {
        expect(File('assets/phrases/gloss_a1_$pair.json').existsSync(), isTrue, reason: pair);
        expect(File('assets/cefr/glossary/${pair.toUpperCase()}/glossary_A1.txt').existsSync(),
            isTrue, reason: pair);
      }
    });

    test('нет глоссария — перевод элемента целиком, а не пустота', () {
      // Уровень без словаря не должен ломать Тренировку: она обязана
      // работать на всех шести с первого дня.
      final words = PhraseGlossary.wordsOf(
        level: 5,
        native: 'ru',
        target: 'en',
        phraseInLevel: 0,
        elementIndex: 0,
        nativeElement: 'Я встаю',
        targetElement: 'I get up',
      );
      expect(words.map((w) => w.word), ['Я', 'встаю']);
      expect(words.every((w) => w.translation == 'I get up'), isTrue);
    });

    test('одно и то же слово не попадает в колоду дважды', () {
      // Ключ слова — слово плюс перевод: «в»=at из одной фразы и «в»=in из
      // другой это разные карточки, а два одинаковых «в»=at — одна.
      const a = GlossedWord(word: 'в', translation: 'at', context: 'at seven');
      const b = GlossedWord(word: 'В', translation: 'At', context: 'at six');
      const c = GlossedWord(word: 'в', translation: 'in', context: 'in the park');
      expect(a.key, b.key);
      expect(a.key, isNot(c.key));
    });
  });

  group('Тренировка', () {
    test('нижняя строка меняет смысл, а не стоит второй кнопкой', () {
      // Пока слов мало, подтверждать нечего: две кнопки рядом заставляли бы
      // выбирать там, где выбора нет.
      final s = training();
      expect(s, contains("static const int _minWords = 10;"));
      expect(s, contains("onPressed: enough ? _confirm : _showPhrase"));
      expect(s, contains("Text(enough ? 'ПОДТВЕРДИТЬ' : 'ПРОДОЛЖИТЬ')"));
      expect(s, contains('if (_picked.length < _minWords) return;'));
    });

    test('хамелеон просит выбрать слова, а не перевести фразу', () {
      expect(training(), contains("'Выбери слова, перевод которых ты не знаешь'"));
      // Полоски награды за подсказки здесь нет вовсе: подсказок нет.
      expect(training().contains('HintMeter'), isFalse);
    });

    test('нажимается каждое слово по отдельности', () {
      // В Одиночной Игре переворачивается ЭЛЕМЕНТ целиком, и там это
      // правильно. Здесь наоборот: не знать можно «семь», зная «в».
      final s = training();
      expect(s, contains('class _PickablePhrase'));
      expect(s, contains('void Function(int element, int word) onTap'));
      expect(s, contains('recognizer: _recognizer(i, w)'));
    });

    test('динамик только на изучаемой стороне карточки', () {
      final s = training();
      final card = s.substring(s.indexOf('Widget _cards()'), s.indexOf('Widget _cardsDone()'));
      expect(card, contains('if (_flipped) ...['));
      expect(card, contains('SpeakButton(text: word.translation, languageCode: _targetLanguage)'));
    });

    test('в конце — та же фраза и тот же раунд, что в Одиночной Игре', () {
      // Вторая копия записи, отправки и ожидания разбора разошлась бы с
      // оригиналом на первой же правке.
      expect(training(), contains("context.pushReplacement('/training?phrase="));
      expect(solo(), contains('final int? fixedPhraseIndex;'));
      expect(solo(), contains('_phraseOrder = widget.fixedPhraseIndex != null'));
      expect(read('lib/core/router.dart'), contains("state.uri.queryParameters['phrase']"));
    });

    test('наборов слов не осталось ни в магазине, ни в настройках', () {
      final shop = read('lib/features/shop/shop_screen.dart');
      expect(shop.contains("'Слова'"), isFalse);
      expect(shop.contains('WordPackInfo'), isFalse);
      expect(read('lib/features/profile/settings_screen.dart').contains('training_deck_size'), isFalse);
      expect(read('lib/data/training_session.dart').contains('trainingDeckSizes'), isFalse);
    });
  });

  group('раунды Одиночной Игры', () {
    test('предела нет, и знаменатель не пишем', () {
      final s = solo();
      expect(s, contains('const int? _roundsPerSession = null;'));
      expect(s, contains("_totalRounds == null ? 'Раунд \$_roundNumber'"));
      // Выйти надо чем-то: сессия больше не кончается сама.
      expect(s, contains("child: const Text('Завершить')"));
    });

    test('проверка уровня по-прежнему в один раунд', () {
      final s = solo();
      expect(s, contains('const _roundsPerPlacement = 1;'));
      expect(s, contains('widget.isSingleRound ? _roundsPerPlacement : _roundsPerSession'));
    });
  });

  group('достижения', () {
    test('на вид — ровно одна плашка', () {
      // Серая рядом с полученной читалась бы как «ты это ещё не сделал».
      final slot = AchievementSlot(
        kind: AchievementKind.unstoppable,
        earnedTier: 10,
        nextTier: 5,
      );
      expect(slot.earned, isTrue);
      expect(slot.detail, 'Продержаться в одиночной игре 10 раундов подряд');

      const empty = AchievementSlot(
        kind: AchievementKind.unstoppable,
        earnedTier: null,
        nextTier: 5,
      );
      expect(empty.earned, isFalse);
      expect(empty.detail, 'Продержись в одиночной игре 5 раундов подряд');
    });

    test('в профиле ДОСТИЖЕНИЯ вместо ИНВЕНТАРЯ', () {
      final s = profile();
      expect(s, contains("Text('ДОСТИЖЕНИЯ'"));
      expect(s.contains("Text('ИНВЕНТАРЬ'"), isFalse);
      expect(s, contains('class _AchievementBadge'));
      // Серая — той же формы, просто серым цветом внутри.
      expect(s, contains('earned ? AppColors.gold : AppColors.muted'));
    });

    test('выдаёт сервер, а не клиент', () {
      // Достижение, которое клиент выдаёт себе сам, — не достижение.
      final migration = read('supabase/migrations/0050_achievements.sql');
      expect(migration, contains('create policy achievements_select_own'));
      expect(migration.contains('for insert'), isFalse);
      expect(migration, contains('security definer'));
      // Идемпотентно и добирает пропущенные ступени.
      expect(migration, contains('on conflict (user_id, kind, tier) do nothing'));
      expect(migration, contains('generate_series(v_step, p_rounds - (p_rounds % v_step), v_step)'));
      expect(solo(), contains('if (!widget.isSingleRound) _awardStreak(_roundNumber);'));
    });

    test('видов ровно один — больше пока не просили', () {
      expect(AchievementKind.values.length, 1);
      expect(AchievementKind.unstoppable.title, 'Неудержимый');
    });
  });
}
