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
    // приходит в него roundPrompt. Эталон воркер теперь и не читает.
    expect(worker(), contains('await roundPrompt(supabase, recording, nativeLanguage)'));
    expect(worker().contains('roundPhrase'), isFalse);
  });

  test('второго вызова за расшифровкой нет', () {
    // Она приходит тем же единственным вызовом, отдельного прохода по
    // аудио не делаем.
    final s = omni();
    expect(s.contains('wantJudgement'), isFalse);
  });

  test('цитату сказанного модель не чинит', () {
    // В плашке ошибки и в зачёркнутом куске должны стоять слова игрока, а
    // не исправленный за него вариант: иначе он не узнает свою ошибку.
    expect(omni(), contains('quoted verbatim with the mistake left in'));
    expect(omni(), contains('never correct them there'));
    // И расшифровка — дословная, а не приглаженная.
    expect(omni(), contains('with every mistake left in'));
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
    expect(worker(), contains('scoreFor(judged.review, judged.errors.length)'));
  });

  test('разбор доезжает до экрана лентой кусков', () {
    expect(omni(), contains('export type SpanKind'));
    expect(worker(), contains('review_spans: reviewSpans'));
    expect(read('lib/widgets/correction_text.dart'), contains('List<TextSpan> reviewSpans('));
  });

  test('модель обязана сказать, слышит ли она речь', () {
    // Модель, до которой аудио не доехало, отвечает своим переводом без
    // единой ошибки: игрок получает десятку за что угодно, и по ответу
    // этого не видно. Явный вопрос превращает молчаливую ложь в отказ.
    expect(omni(), contains(r'\"audible\": true or false'));
    expect(omni(), contains('if (parsed.audible === false)'));
    expect(omni(), contains('audible=false'));
  });

  test('ленту строит код, а не модель', () {
    // Дважды подряд модель размечала её неверно: то помечала сказанное как
    // пропущенное, то объявляла «ошибок нет» на половине фразы. Сравнить
    // две строки по словам — арифметика, и её надо считать, а не
    // спрашивать.
    final s = omni();
    expect(s, contains('ribbon(diffWords(heard, correct))'));
    expect(s.contains('parsed.review'), isFalse);
    expect(read('supabase/functions/_shared/textDiff.ts'), contains('export function diffWords'));
  });

  test('расшифровка обязательна и не показывается игроку', () {
    // Она нужна не экрану, а сравнению: без неё модель не представляет
    // сказанное явно и по умолчанию соглашается, что всё верно.
    final s = omni();
    expect(s, contains('THE TRANSCRIPTION IS THE POINT OF THIS TASK'));
    expect(s, contains('в ответе нет расшифровки'));
    // На экране её нет: блок «Голосовое:» убран и не возвращается.
    expect(read('lib/widgets/transcript_review.dart').contains('Голосовое'), isFalse);
  });

  test('пропуск, выданный за ошибку, не снимает балл второй раз', () {
    // Модель регулярно присылает «сказал X, надо X» с объяснением «эту
    // часть не сказали». Долю несказанного мы уже посчитали по ленте.
    expect(omni(), contains('if (correction.length > 0 && correction === text) continue;'));
    expect(omni(), contains('NEVER put an omission in'));
  });

  test('пробел на стыке кусков восстанавливается', () {
    // «every morning» + «then I» слипались в «morningthen» — это игрок
    // видел на экране. Дифф отдаёт голые слова, пробелы ставит склейка.
    expect(omni(), contains('out[i].text += " ";'));
  });

  test('в промпте есть разобранный пример', () {
    // Пример показывает главное: расшифровка обрывается там, где игрок
    // замолчал, и пропуск не превращается в запись об ошибке.
    final s = omni();
    expect(s, contains('Example. The learner was asked to say'));
    expect(s, contains('"heard" stops where the learner stopped'));
  });

  test('сырой ответ модели сохраняется', () {
    // Когда балл выглядит взятым с потолка, спорить можно только по нему.
    expect(omni(), contains('debug.raw = raw.slice'));
    expect(read('lib/features/training/training_screen.dart'), contains("judge?['raw']"));
  });

  test('один вызов — одно списание', () {
    final w = worker();
    // Прежняя связка стоила 1 (распознавание) + 2 (разбор). Один вызов
    // делает работу обоих, и цена та же.
    expect(w, contains('ENERGY_COST_OMNI") ?? 3'));
    expect(w, contains('energy.charge(ENERGY_COST_OMNI'));
    // Платим только за ответ: отказ провайдера бесплатен.
    expect(w, contains('if (!omni.degraded) {'));
  });

  test('распознавания и текстового судьи в пайплайне нет', () {
    final w = worker();
    for (final gone in ['transcribeAudio', 'resolveTranscript', 'evaluateGrammar', 'ASR_']) {
      expect(w.contains(gone), isFalse, reason: gone);
    }
    // И самих файлов тоже: выключенный путь, который нельзя включить, —
    // это не запас, а мусор.
    for (final path in [
      'supabase/functions/_shared/asr',
      'supabase/functions/_shared/evaluateGrammar.ts',
      'supabase/functions/_shared/llmChat.ts',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
  });

  test('ошибки модели рисуются своими плашками', () {
    final screen = read('lib/features/training/training_screen.dart');
    // Границы модель провела по смыслу сказанного; разложить их по
    // элементам эталона нечем — у неё эталона не было вовсе.
    expect(screen, contains('class _MistakeBreakdown'));
    expect(screen, contains("if ((e['category'] as String?) != 'omni') continue;"));
    // Поэлементного разбора больше нет: держать рядом две несовместимые
    // механики значило бы поддерживать ту, которой никто не пользуется.
    expect(screen.contains('_ElementBreakdown'), isFalse);
    expect(screen.contains('_messagesByIndex'), isFalse);
    // Подсказки по элементам эталона при этом остались — это другая
    // механика: открыть перевод одной части фразы, не открывая остальные.
    expect(screen, contains('PhraseBank.elementsFor'));
  });
}
