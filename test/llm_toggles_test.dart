import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Два переключателя решают, где в раунде участвует модель. Проверки
/// читают сами файлы: значения по умолчанию и порядок «настройка игрока
/// главнее окружения» легко сломать правкой в одну строку, а заметно это
/// станет только по счёту, который игрок не заказывал.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('по умолчанию оба выключены — это нынешнее поведение, не новое', () {
    final sql = read('supabase/migrations/0033_llm_toggles.sql');
    // false у обоих означает: балл считается по элементам, разбор берётся
    // из датасета. Ровно так работало до появления настроек, и миграция
    // не имеет права менять это молча для тех, кто её просто накатил.
    expect(sql, contains('llm_scoring_enabled boolean not null default false'));
    expect(sql, contains('llm_explanations_enabled boolean not null default false'));
  });

  test('настройка игрока главнее переменных окружения', () {
    final prefs = read('supabase/functions/_shared/playerPrefs.ts');
    // Обратный порядок дал бы переключатель, который иногда молча не
    // работает: хуже выключенной настройки только настройка,
    // притворяющаяся включённой.
    expect(prefs, contains('llm_scoring_enabled'));
    expect(prefs, contains('llm_explanations_enabled'));
    expect(prefs, contains('prefsFromEnv'));
    // К окружению обращаемся только на путях отказа.
    for (final onFailure in [
      'нет игрока в записи',
      'строки игрока нет',
    ]) {
      expect(prefs, contains(onFailure));
    }
  });

  test('чтение настроек не может уронить оценку раунда', () {
    // Балл уже посчитан, аудио уже потрачено. Уронить запись результата
    // из-за строки конфигурации — обмен ценного на необязательное.
    final prefs = read('supabase/functions/_shared/playerPrefs.ts');
    expect(prefs, contains('catch'));
    expect(prefs, contains('НИКОГДА НЕ БРОСАЕТ'));
  });

  test('воркер решает по настройкам, а не по константе', () {
    final worker = read('supabase/functions/evaluate-recording/index.ts');
    expect(worker, contains('loadPlayerPrefs(supabase, recording.user_id)'));
    expect(worker, contains('prefs.llmScoring ? null : scoreByElements'));
    // Датасет предпочитается ровно когда объяснения от модели выключены.
    expect(worker, contains('!prefs.llmExplanations'));
    // Старой глобальной константы в решениях воркера быть не должно:
    // иначе переключатель игрока перебивался бы деплоем.
    expect(worker.contains('JUDGE_ENABLED ?'), isFalse);
    expect(worker.contains('!JUDGE_ENABLED'), isFalse);
  });

  test('датасет остаётся запасным вариантом при включённых объяснениях', () {
    // И наоборот. Второй источник не запрещён, он отодвинут: показать
    // пустоту, имея готовый текст рядом, значило бы наказать за настройку.
    final screen = read('lib/features/training/training_screen.dart');
    expect(screen, contains('final preferModel = GameSettings.llmExplanations;'));
    expect(screen, contains('final fallback = preferModel ? fromDataset : fromModel;'));
  });

  test('кэш настроек не бросает до входа в аккаунт', () {
    // currentUserId до входа бросает, и загрузка настроек уронила бы
    // стартовый экран ради двух булевых полей.
    final settings = read('lib/core/game_settings.dart');
    // Проверяем именно load(): сеттеры зовутся только с экрана настроек,
    // куда без входа не попасть, и там currentUserId уместен — он громко
    // падает, если вызвать его не оттуда.
    final load = settings.substring(
      settings.indexOf('static Future<void> load()'),
      settings.indexOf('static Future<void> setLlmScoring'),
    );
    expect(load, contains('supabase.auth.currentUser?.id'));
    // Ищем именно обращение в запросе: слово currentUserId в load() есть и
    // должно быть — в комментарии, объясняющем, почему его тут нет.
    expect(load.contains("eq('id', currentUserId)"), isFalse);
  });

  test('неудачное сохранение возвращает переключатель на место', () {
    // Иначе игрок уйдёт с экрана уверенным, что настройка сменилась, а
    // сервер продолжит считать по-старому.
    final settings = read('lib/core/game_settings.dart');
    expect(settings, contains('llmScoring = previous;'));
    expect(settings, contains('llmExplanations = previous;'));
    expect(read('lib/features/profile/settings_screen.dart'), contains('revert()'));
  });
}
