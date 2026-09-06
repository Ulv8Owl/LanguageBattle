import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Мультимодальная модель слушает запись и судит перевод сама. Ключевое
/// свойство этой замены — она НЕ ВИДИТ ЭТАЛОНА: у фразы почти всегда
/// несколько верных переводов, и сверка с одним из них наказывала за
/// правильный ответ, сказанный иначе. Свойство легко потерять одной
/// строчкой, поэтому оно закреплено здесь.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String omni() => read('supabase/functions/_shared/omniJudge.ts');
  String worker() => read('supabase/functions/evaluate-recording/index.ts');

  test('эталон модели не показывают', () {
    final s = omni();
    // В запрос уходит задание на родном языке и звук — и всё. Ни
    // generated_phrase, ни expectedPhrase, ни какого-либо «правильного
    // ответа» здесь быть не должно.
    for (final forbidden in ['expectedPhrase', 'generated_phrase', 'markedText']) {
      expect(s.contains(forbidden), isFalse, reason: forbidden);
    }
    expect(s, contains('This is your reference — you have no other'));
    // И воркер не передаёт эталон в вызов: параметр называется prompt, и
    // приходит в него roundPrompt, а не roundPhrase.
    expect(worker(), contains('await roundPrompt(supabase, recording, nativeLanguage)'));
  });

  test('в режиме «только услышать» задание тоже не уходит', () {
    // Зная ожидаемый смысл, модель склонна дописывать за игрока то, чего
    // он не сказал, — а транскрипт нужен ровно как сказано.
    final s = omni();
    expect(s, contains('if (req.wantJudgement) {\n    userParts.push('));
  });

  test('модель просят не чинить услышанное', () {
    final s = omni();
    expect(s, contains('mistakes included. Do not fix anything'));
    expect(s, contains('Do not correct, complete or rephrase'));
  });

  test('ошибки группируются по смыслу, а не по словам', () {
    // Это и есть просьба игрока: не привязываться к структуре элементов, а
    // объединять в одну ошибку всё, что пошло не так по одной причине.
    expect(omni(), contains('Group errors by MEANING'));
  });

  test('поток обязателен, аудио на выходе не просим', () {
    final s = omni();
    // Без stream сервис отвечает ошибкой.
    expect(s, contains('stream: true'));
    // Озвучка у нас своя (Cloud TTS): просить у модели ещё и звук значило
    // бы платить за то, что тут же выбросим.
    expect(s, contains('modalities: ["text"]'));
  });

  test('сбой провайдера не роняет задачу', () {
    // Иначе задача осталась бы висеть в processing, а игрок ждал бы
    // результат, которого не будет.
    expect(omni(), contains('НИКОГДА НЕ БРОСАЕТ'));
    expect(omni(), contains('degraded: true'));
  });

  test('ошибка без фрагмента или без объяснения не показывается', () {
    // Плашка — это и есть фрагмент; без объяснения за ней ничего нет.
    expect(omni(), contains('if (text.length === 0 || message.length === 0) continue;'));
    expect(read('lib/features/training/training_screen.dart'),
        contains('if (span.isEmpty || message.isEmpty) continue;'));
  });

  test('язык объяснений называется дважды и самоназванием', () {
    // Инструкция «explain in Russian» однажды была прочитана как пожелание,
    // и игрок с русским в паре получил разбор на испанском. Самоназвание —
    // второй, независимый указатель: его труднее перепутать, потому что
    // оно написано той же письменностью, что и требуемый ответ.
    final s = omni();
    expect(s, contains('LANGUAGE_ENDONYMS'));
    expect(s, contains(r'(${nativeSelf})'));
    expect(s, contains('and in no other'));
  });

  test('родной язык берётся от активной пары, а не наугад', () {
    // maybeSingle на двух парах с одним изучаемым языком возвращает ошибку
    // и пустые данные — родной молча откатывался на общий, и объяснения
    // приходили на языке другой пары.
    final w = worker();
    expect(w, contains('.order("is_active", { ascending: false })'));
    expect(w.contains('.eq("language_code", targetLanguage)\n      .maybeSingle()'), isFalse);
  });

  test('балл считает программа, а не модель', () {
    // Числовая оценка от модели гуляла на два-три балла на одной записи и
    // не объяснялась игроку.
    final s = omni();
    expect(s, contains('export function scoreFor'));
    expect(s.contains('clampScore'), isFalse);
    expect(worker(), contains('scoreFor(judged.correct, judged.missing, judged.errors.length)'));
  });

  test('несказанное — отдельная категория, а не ошибка', () {
    // Как ошибка пропуск дал бы плашку, за которой пусто; как пропуск
    // ошибка потеряла бы разбор.
    expect(worker(), contains('category: "missing"'));
    expect(read('supabase/migrations/0038_missing_spans.sql'), contains("'missing'"));
    expect(read('lib/features/training/training_screen.dart'), contains('_missingSpans'));
  });

  test('один вызов — одно списание', () {
    final w = worker();
    // Прежняя связка стоила 1 (распознавание) + 2 (разбор). Один вызов
    // делает работу обоих, и цена та же.
    expect(w, contains('ENERGY_COST_OMNI") ?? 3'));
    expect(w, contains('energy.charge(ENERGY_COST_OMNI'));
    // Платим только за ответ: отказ и повторный прогон по сохранённому
    // транскрипту бесплатны.
    expect(w, contains('!omni.degraded && heardBy.debug.cached !== true'));
  });

  test('старый путь остаётся, переключается переменной', () {
    final w = worker();
    expect(w, contains('if (omniEnabled()) {'));
    expect(w, contains('resolveTranscript('));
    expect(omni(), contains('Deno.env.get("OMNI_ENABLED") ?? "0"'));
  });

  test('ошибки модели рисуются своими плашками', () {
    final screen = read('lib/features/training/training_screen.dart');
    // Границы модель провела по смыслу сказанного; разложить их по
    // элементам эталона нечем — у неё эталона не было вовсе.
    expect(screen, contains('class _MistakeBreakdown'));
    expect(screen, contains("if ((e['category'] as String?) != 'omni') continue;"));
    // Подсказки по элементам эталона при этом никуда не делись.
    expect(screen, contains('class _ElementBreakdown'));
  });
}
