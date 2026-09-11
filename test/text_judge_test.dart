import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Судья на этой ветке ДВУХШАГОВЫЙ: распознавание превращает речь в текст,
/// текстовая модель этот текст судит. Общее с веткой Omni — лента, балл и
/// проверки — лежит в review.ts и обязано остаться тем же: иначе сравнение
/// двух архитектур измеряло бы не модели, а разницу в нашей арифметике.
///
/// Наш перевод судья получает ОРИЕНТИРОМ по смыслу: он решает, ЧТО должно
/// быть сказано, и не решает, КАКИМИ СЛОВАМИ. Сдвиньте эту границу — и
/// вернётся либо придирка к верному переводу, либо полфразы на десятку.
/// ПОЧЕМУ ЗДЕСЬ НЕТ ДОСЛОВНЫХ ЦИТАТ ИЗ ПРОМПТА. Были — и ломались на каждой
/// правке формулировки, а промпт правят чаще любого кода вокруг: он для
/// того и вынесен отдельным файлом, чтобы менять его свободно. Три раза
/// подряд тесты падали не потому, что что-то сломалось, а потому, что фразу
/// переписали лучше.
///
/// Поэтому проверяется КОНТРАКТ, а не текст: имена полей, которые читает
/// код, наличие подстановок, поведение при пустом образце — и по одному
/// устойчивому признаку на каждое правило, которое родилось из настоящего
/// бага. Признак берётся такой, который переживёт переписывание абзаца.
void main() {
  String read(String path) => File(path).readAsStringSync();

  // На этой ветке судья двухшаговый: распознавание плюс текстовая
  // модель. Общее ядро — лента, балл, проверки — лежит в review.ts.
  String omni() => read('supabase/functions/_shared/review.ts');
  String judge() => read('supabase/functions/_shared/textJudge.ts');
  String asr() => read('supabase/functions/_shared/asr.ts');
  String prompt() => read('supabase/functions/_shared/prompts/judgeText.ts');
  String worker() => read('supabase/functions/evaluate-recording/index.ts');

  test('наш перевод — ориентир, а не эталон', () {
    final s = prompt();
    // Три вещи, без любой из которых образец снова станет эталоном.
    // Образец решает СМЫСЛ и не решает СЛОВА — обе половины обязательны.
    // Без первой модель не видит подмены дня недели и пропущенной половины
    // фразы; без второй объявляет ошибкой верный перевод, сказанный иначе.
    expect(s, contains('Use it for MEANING ONLY'));
    expect(s, contains('It does NOT tell you which words to use'));
    // Без образца блока нет вовсе: пустая строка на его месте читалась бы
    // как «правильный перевод — пустота».
    // Без образца судья переводит задание сам, и ему об этом говорят прямо.
    expect(s, contains('if (v.reference.length === 0)'));
    expect(s, contains('Translate the task into'));
    // Воркер читает образец из того же поля, куда его пишет клиент.
    expect(worker(), contains('await roundPrompt(supabase, recording, nativeLanguage)'));
    expect(worker(), contains('await roundReference(supabase, recording)'));
    expect(worker(), contains('.select("generated_phrase")'));
  });

  test('промпт лежит отдельным читаемым файлом', () {
    // Промпт меняют чаще любого кода вокруг, и россыпь строк в середине
    // адаптера означала, что править его боязно.
    expect(judge(), contains('import { judgeTextPrompt } from "./prompts/judgeText.ts";'));
    expect(prompt(), contains('export function judgeTextPrompt(v: JudgeTextVars): string {'));
  });

  test('ссылка для распознавания кончается на .wav и не открывает лишнего', () {
    // Провайдер определяет формат ПО РАСШИРЕНИЮ В ССЫЛКЕ: подписанная
    // ссылка Supabase кончается на `.wav?token=…`, и одна модель отвечает
    // «format is empty», другая — «url error, please check url!».
    final link = read('supabase/functions/_shared/audioLink.ts');
    expect(link, contains('/functions/v1/asr-audio/'));
    expect(link, contains(r'${token}.${ext}'));
    // Подписываем путь И СРОК вместе: подпись только пути дала бы вечную
    // ссылку, подпись только срока — подстановку чужого файла.
    expect(link, contains(r'const payload = `${storagePath}|${exp}`;'));

    // ПУБЛИЧНЫМ БАКЕТ НЕ СТАНОВИТСЯ. Он решал бы ту же задачу одной
    // строкой, но ценой того, что голос игрока читает кто угодно.
    for (final f in Directory('supabase/migrations').listSync().whereType<File>()) {
      final sql = f.readAsStringSync();
      expect(sql.contains("'voice-recordings', true"), isFalse, reason: f.path);
    }

    // Функция отдаёт файл только по действующей подписи — и одинаково
    // молчит на истёкший, подделанный и испорченный токен.
    final fn = read('supabase/functions/asr-audio/index.ts');
    expect(fn, contains('if (path === null) return new Response("not found", { status: 404 });'));
    expect(fn.contains('list('), isFalse, reason: 'бакет не листается');
    // Деплой без проверки JWT — обязателен: провайдеру взять токен неоткуда.
    expect(read('tools/deploy_server.sh'), contains('deploy asr-audio --no-verify-jwt'));
  });

  test('первым шагом стоит модель, которая работает', () {
    // Пять кругов проверок: тело запроса у нас побайтово такое же, как у
    // вызова, который месяц работает с qwen3-omni-flash, — отличается ровно
    // имя модели, и специальные модели распознавания всё равно отвечают
    // отказом. Держать ветку сломанной ради экономии, которой пока нет,
    // нельзя: она сначала должна работать.
    final s = asr();
    final list = s.substring(s.indexOf('export const ASR_MODELS'), s.indexOf('] as const;'));
    expect(list.indexOf('"qwen3-omni-flash"'), lessThan(list.indexOf('"qwen-audio-3.0-asr-flash"')),
        reason: 'рабочая модель должна стоять первой — она по умолчанию');
    // Нерабочие из списка не убраны: вернуть экономию, когда станет
    // известна форма вызова, должно быть делом одного переключателя.
    expect(list, contains('"fun-asr-mtl"'));
    // Мультимодальной лесенка не нужна — её форма известна и проверена.
    expect(s, contains('const multimodal = model.includes("omni");'));
    expect(s, contains('if (url.length > 0 && !multimodal) {'));
    // Списки клиента и сервера обязаны совпадать: значение из профиля это
    // ввод снаружи, и проверяется оно там, где им пользуются.
    final dart = read('lib/data/judge_models.dart');
    for (final m in ['qwen3-omni-flash', 'qwen3.5-omni-flash', 'fun-asr-mtl']) {
      expect(dart, contains("'$m'"), reason: m);
    }
  });

  test('распознавание пробует три формы вызова, а не одну', () {
    // Провайдер обслуживает эти модели НЕ так, как мультимодальную, и как
    // именно — по документации было не угадать. Совместимый путь отвечал
    // «format is empty» на всё подряд, а на fun-asr-mtl честно сказал:
    // «Unsupported model for OpenAI compatibility mode». Значит у моделей
    // распознавания своя схема, и пробовать надо обе.
    final s = asr();
    // Форма, заведомо работающая с мультимодальной моделью: вложение плюс
    // текстовая часть. Для неё она единственная и нужная.
    expect(s, contains('name: "compat-inline"'));
    expect(s, contains('audioPart(req.audio, req.audioFormat)'));
    expect(s, contains('{ type: "text", text: "Transcribe this recording." }'));
    // Ссылкой — и обязательно с форматом: в подписанной ссылке есть токен,
    // и расширение из неё вычитывается неверно.
    expect(s, contains('name: "compat-url"'));
    expect(s, contains('input_audio: { data: url, format: req.audioFormat }'));
    // И своя схема провайдера — другой путь и другое тело. Она идёт ПЕРВОЙ:
    // именно там fun-asr-mtl дошёл до проверки ссылки, а не до отказа в
    // модели, — значит эти модели провайдер держит там.
    expect(s, contains('shapes.unshift({ name: "native-url"'));
    expect(s, contains('/api/v1/services/aigc/multimodal-generation/generation'));
    // Какая форма прошла и что ответили остальные — в отладке записи.
    expect(s, contains('shape: shape.name'));
    expect(s, contains('attempts,'));
  });

  test('лесенка останавливается на первой ответившей', () {
    final s = asr();
    // Неудача — не повод бросать: пробуем следующую форму.
    expect(s, contains('attempts.push({ shape: shape.name, ok: false'));
    expect(s, contains('continue;'));
    // Успех — возврат сразу, лишних вызовов не делаем.
    expect(s, contains('attempts.push({ shape: shape.name, ok: true'));
    // И бюджет раунда лесенка не проедает: без запаса времени не начинаем.
    expect(s, contains('if (left() < 5_000)'));
  });

  test('вызова ровно два, и за аудио платит только первый', () {
    // В этом весь смысл ветки: аудио идёт в распознавание — модель
    // заточенную под одно дело, — а судье достаётся текст, который стоит
    // копейки. Третьего вызова нет: транспорт один на оба шага.
    expect(asr(), contains('export async function transcribe'));
    expect(judge(), contains('const asr = await transcribe('));
    expect(judge(), contains('const answer = await requestQwen('));
    expect(omni(), contains('export async function requestQwen'));
  });

  test('цитату сказанного модель не чинит', () {
    // В плашке ошибки и в зачёркнутом куске должны стоять слова игрока, а
    // не исправленный за него вариант: иначе он не узнает свою ошибку.
    // Слова игрока остаются в «правильном переводе» везде, где он был прав.
    expect(prompt(), contains('HIS OWN WORDS everywhere he was right'));
    expect(prompt(), contains('must leave every one of them untouched'));
  });

  test('ошибки группируются по смыслу, а не по словам', () {
    // Это и есть просьба игрока: не привязываться к структуре элементов, а
    // объединять в одну ошибку всё, что пошло не так по одной причине.
    // Подряд идущее несказанное — ОДИН кусок любой длины.
    expect(prompt(), contains('did not say is ONE entry, however long'));
  });

  test('поток обязателен, аудио на выходе не просим', () {
    final s = omni();
    // Без stream сервис отвечает ошибкой.
    expect(s, contains('stream: true'));
    // modalities едет ТОЛЬКО со звуком: текстовые модели на незнакомое поле
    // отвечают HTTP 400, а их в списке судей два десятка.
    expect(s, contains('...(opts.audio ? { modalities: ["text"] } : {})'));
  });

  test('сбой провайдера не роняет задачу', () {
    // Иначе задача осталась бы висеть в processing, а игрок ждал бы
    // результат, которого не будет.
    expect(judge(), contains('НИКОГДА НЕ БРОСАЕТ'));
    expect(judge(), contains('degraded: true'));
    // И распознавание тоже: сбой первого шага — это degraded, а не падение.
    expect(asr(), contains('НИКОГДА НЕ БРОСАЕТ'));
  });

  test('ошибка без фрагмента или без объяснения не показывается', () {
    // Плашка — это и есть фрагмент; без объяснения за ней ничего нет.
    // Кусок без перевода остаётся красным, но нажимать на него не на что:
    // показать перевод НЕ ОТ ТОГО куска хуже, чем не показать никакого.
    expect(omni(), contains('if (key.length === 0 || means.length === 0) continue;'));
    expect(read('lib/widgets/correction_text.dart'),
        contains("bool get hasMeaning => kind == 'miss' && means.isNotEmpty;"));
  });

  test('язык объяснений называется дважды и самоназванием', () {
    // Инструкция «explain in Russian» однажды была прочитана как пожелание,
    // и игрок с русским в паре получил разбор на испанском. Самоназвание —
    // второй, независимый указатель: его труднее перепутать, потому что
    // оно написано той же письменностью, что и требуемый ответ.
    final s = omni();
    expect(s, contains('LANGUAGE_ENDONYMS'));
    expect(prompt(), contains(r'(${v.nativeSelf})'));
    expect(prompt(), contains('and no other language'));
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
    // Списка ошибок здесь нет вовсе, поэтому балл — это только доля
    // несказанного. Двойного счёта не появляется, а исчезает: неверное
    // слово и так попадает в эту долю.
    expect(worker(), contains('scoreFor(judged.review, judged.errors.length)'));
    expect(judge(), contains('errors: [],'));
  });

  test('разбор доезжает до экрана лентой кусков', () {
    expect(omni(), contains('export type SpanKind'));
    expect(worker(), contains('review_spans: reviewSpans'));
    expect(read('lib/widgets/correction_text.dart'), contains('List<TextSpan> reviewSpans('));
  });

  test('нашлась ли речь — решает пустая расшифровка, а не вопрос', () {
    // На ветке Omni у модели об этом спрашивали прямо: она слышит запись и
    // могла ответить своим переводом, не услышав ничего. Здесь спрашивать
    // некого — судья записи не слышит вовсе, а распознавание либо принесло
    // текст, либо нет. Это честнее вопроса.
    expect(judge(), contains('if (asr.text.length === 0)'));
    expect(judge(), contains('silent: true,'));
    expect(judge(), contains('распознаватель не нашёл речи в записи'));
  });

  test('ленту строит код, а не модель', () {
    // Дважды подряд модель размечала её неверно: то помечала сказанное как
    // пропущенное, то объявляла «ошибок нет» на половине фразы. Сравнить
    // две строки по словам — арифметика, и её надо считать, а не
    // спрашивать.
    final s = judge();
    expect(s, contains('ribbon(diffWords(asr.text, correct))'));
    expect(s.contains('parsed.review'), isFalse);
    expect(read('supabase/functions/_shared/textDiff.ts'), contains('export function diffWords'));
  });

  test('расшифровка обязательна и не показывается игроку', () {
    // Она нужна не экрану, а сравнению: без неё модель не представляет
    // сказанное явно и по умолчанию соглашается, что всё верно.
    // Расшифровку даёт распознавание, а не судья: судье её ПОКАЗЫВАЮТ.
    expect(prompt(), contains('WHAT HE SAID, as the recogniser wrote it down'));
    // И предупреждают, что писала её машина: знаки препинания и заглавные
    // буквы принадлежат ей, а не игроку.
    expect(prompt(), contains('TYPED BY A MACHINE, NOT BY HIM'));
    // На экране её нет: блок «Голосовое:» убран и не возвращается.
    expect(read('lib/widgets/transcript_review.dart').contains('Голосовое'), isFalse);
  });

  test('пропуск, выданный за ошибку, не снимает балл второй раз', () {
    // Модель регулярно присылает «сказал X, надо X» с объяснением «эту
    // часть не сказали». Долю несказанного мы уже посчитали по ленте.
    // Пропуск и есть красный текст в ленте — отдельной записи о нём быть
    // не может: списка ошибок на этой ветке нет вовсе.
    expect(prompt(), contains('one entry for every stretch of "correct" that is NOT in what he said'));
    expect(judge(), contains('errors: [],'));
  });

  test('пробел на стыке кусков восстанавливается', () {
    // «every morning» + «then I» слипались в «morningthen» — это игрок
    // видел на экране. Дифф отдаёт голые слова, пробелы ставит склейка.
    expect(omni(), contains('out[i].text += " ";'));
  });

  test('разобранных примеров в промпте НЕТ, и это правило', () {
    // Пример стоял на «Я встаю в семь. Потом я варю кофе…» — первой фразе
    // банка A1, которую игроки читают чаще любой другой, — и показывал
    // готовый список ошибок. Модель его и переписывала: игрок сказал верное
    // «wake up» и получил «надо get up», а правка «at seven» пришла без
    // «o'clock» — ровно как в примере. Пример на задании, которое сейчас
    // проверяют, это не образец рассуждения, а готовый ответ.
    expect(prompt().contains('Example. The learner was asked to say'), isFalse);
    expect(prompt().contains('Second example'), isFalse);
    // И по той же причине запрещённые придирки не перечисляются поимённо:
    // названная пара становится модели доступной.
    expect(prompt().contains('"After that" instead of "Then"'), isFalse);
    // Правило записано в шапке файла, чтобы его не вернули по недосмотру.
    expect(prompt(), contains('ВОЗВРАЩАЮТСЯ ПАРАМИ'));
  });

  test('сырой ответ модели сохраняется', () {
    // Когда балл выглядит взятым с потолка, спорить можно только по нему.
    expect(judge(), contains('raw: raw.slice(0, 2000)'));
    expect(read('lib/features/training/training_screen.dart'), contains("judge?['raw']"));
  });

  test('один вызов — одно списание', () {
    final w = worker();
    // Вызова два, а списание одно: игрок платит за разбор, а не за наше
    // устройство пайплайна.
    expect(w, contains('ENERGY_COST_JUDGE'));
    expect(w, contains('energy.charge(ENERGY_COST_JUDGE'));
    // Платим только за ответ: отказ провайдера бесплатен.
    expect(w, contains('if (!verdict.degraded) {'));
  });

  test('прежних провайдеров в пайплайне нет', () {
    // Распознавание вернулось, но своё и на том же ключе qwencloud, а не
    // прежняя россыпь Google/Deepgram/OpenAI с отдельными адаптерами.
    final w = worker();
    for (final gone in ['transcribeAudio', 'resolveTranscript', 'evaluateGrammar']) {
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

  test('плашка — это сам красный текст, а не список под лентой', () {
    final screen = read('lib/features/training/training_screen.dart');
    // Отдельного ряда плашек с объяснениями больше нет: они повторяли то,
    // что видно в ленте, и отвечали на вопрос «почему неверно», который
    // игрок не задавал — своё зачёркнутое слово он видит рядом с верным.
    final review = read('lib/widgets/round_review.dart');
    expect(review.contains('class MistakeBreakdown'), isFalse);
    expect(review.contains('mistakesFrom'), isFalse);
    // Нажимается сам кусок, и перевод едет вместе с ним, а не отдельным
    // списком: список пришлось бы сводить с лентой по тексту.
    final ribbon = read('lib/widgets/transcript_review.dart');
    expect(ribbon, contains('TapGestureRecognizer'));
    expect(read('lib/widgets/correction_text.dart'), contains("(item['m'] as String?)"));
    expect(screen, contains('RoundReview('));
    // Поэлементного разбора больше нет: держать рядом две несовместимые
    // механики значило бы поддерживать ту, которой никто не пользуется.
    expect(screen.contains('_ElementBreakdown'), isFalse);
    expect(screen.contains('_messagesByIndex'), isFalse);
    // Подсказки по элементам эталона при этом остались — это другая
    // механика: открыть перевод одной части фразы, не открывая остальные.
    expect(screen, contains('PhraseBank.elementsFor'));
  });
}
