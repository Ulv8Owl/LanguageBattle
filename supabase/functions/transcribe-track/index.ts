/**
 * Разбирает запись игрока на слова со временем и переводом.
 *
 * ЧТО СЮДА ПРИХОДИТ. Ссылка на запись, которую игрок только что залил из
 * памяти телефона, и язык, на который переводить. Запись живёт в хранилище
 * ровно столько, сколько идёт разбор: удаляет её клиент сразу после
 * ответа, а результат кладёт себе на устройство. Ни звука, ни расшифровки
 * мы у себя не держим — это файл игрока, разобранный по его же просьбе.
 *
 * ПОЧЕМУ ОДНА МОДЕЛЬ, А НЕ РАСПОЗНАВАНИЕ ПЛЮС ПЕРЕВОД. Пословный перевод
 * обязан лечь ровно на пословную расшифровку. Разложив их по двум вызовам,
 * мы получаем два независимых разбиения на слова: одно склеит артикль со
 * словом, другое нет — и дальше перевод едет относительно оригинала до
 * конца записи, причём молча. Одна модель выдаёт пару в одном объекте, и
 * разъехаться там нечему.
 *
 * ═══ ФОРМА ВЫЗОВА — ТА ЖЕ, ЧТО У СУДЬИ, И ЭТО НЕ ЛЕНЬ ═══
 *
 * Здесь стоял свой вызов по СВОЕЙ схеме DashScope: эндпоинт
 * `/api/v1/services/aigc/multimodal-generation/generation` и заголовок
 * `X-DashScope-SSE: disable`. Это форма ДРУГОГО семейства моделей
 * (`qwen-audio-3.0-*`), а `qwen3-omni-flash` живёт в совместимом режиме, и
 * поток для него обязателен — без `stream: true` сервис отвечает ошибкой.
 * Как раз от этой путаницы семейств `_shared/asr.ts` и защищается, заплатив
 * за науку пятью кругами отказов «format is empty».
 *
 * Поэтому транспорт здесь общий — `requestQwen`. Своя копия вызова с
 * собственным разбором ответа означала бы, что следующую особенность
 * провайдера чинят в двух местах, а замечают в одном.
 *
 * ЭНЕРГИЯ СПИСЫВАЕТСЯ ЗДЕСЬ, А НЕ НА КЛИЕНТЕ: списание клиентом — это
 * предложение не списывать.
 */

import { createClient } from "jsr:@supabase/supabase-js@2";
import { audioUrlFor } from "../_shared/audioLink.ts";
import { judgeKey, parseJson, requestQwen } from "../_shared/review.ts";
import { asrFamily, nativeTranscribe } from "../_shared/asr.ts";

/** Тот же приватный бакет, что и у боевых записей. */
const BUCKET = "voice-recordings";

/**
 * Длиннее этого не беремся.
 *
 * Потолок наш, а не провайдерский: сколько аудио за раз принимает сама
 * модель, мы на живых записях не мерили. Поэтому он вынесен в секрет —
 * упрётся живой разбор в чужой лимит раньше нашего, его можно подвинуть, не
 * трогая код. Отказ провайдера при этом доезжает до игрока дословно, так
 * что причина будет видна, а не спрятана за нашим числом.
 */
const MAX_DURATION_MS = Number(Deno.env.get("TRANSCRIBE_MAX_MINUTES") ?? "12") * 60 * 1000;

/**
 * Сколько отпущено модели. МЕНЬШЕ ПЛАТФОРМЕННОГО СРОКА, И ЭТО ГЛАВНОЕ.
 *
 * Здесь стояло 240 000 — больше, чем Edge Function вообще живёт. Такой срок
 * не наступает никогда: запрос убивает шлюз, минуя любые catch и finally, и
 * приложение получает голый «сервер ответил 504» — без причины, без
 * подробностей и с уже списанной энергией.
 *
 * Ровно этот урок записан в evaluate-recording: «бюджет теперь наш, он
 * меньше платформенного, и до его конца мы обязаны успеть записать хоть
 * какой-то результат». Там он 125 с; здесь меньше, потому что после модели
 * надо ещё успеть положить разбор в хранилище.
 */
const TIMEOUT_MS = Number(Deno.env.get("TRANSCRIBE_TIMEOUT_MS") ?? "105000");

/** Запас на запись результата. Тратить его на модель нельзя. */
const WRITE_RESERVE_MS = 15_000;

/**
 * Продлевает жизнь воркера после отправки ответа. Есть в рантайме Supabase
 * Edge Functions; объявлено здесь, потому что в типах Deno этого нет.
 */
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

/**
 * Модели разбора «Аудирования». ПЕРВАЯ — ПО УМОЛЧАНИЮ, и это настоящий
 * распознаватель, а не omni: время он измеряет, а не сочиняет. Список тот
 * же, что видит игрок в настройках (lib/data/judge_models.dart) — разойдясь,
 * они дали бы выбор, который сервер молча заменяет на свой.
 */
const LISTENING_MODELS = [
  "qwen-audio-3.0-asr-flash",
  "qwen3-omni-flash",
  "qwen3.5-omni-flash",
] as const;

/** Выбор игрока сильнее окружения; незнакомое значение — модель по умолчанию. */
function listeningModel(chosen?: string | null): string {
  const wanted = (chosen ?? "").trim();
  if ((LISTENING_MODELS as readonly string[]).includes(wanted)) return wanted;
  const fromEnv = Deno.env.get("OMNI_TRANSCRIBE_MODEL");
  if (fromEnv && (LISTENING_MODELS as readonly string[]).includes(fromEnv)) return fromEnv;
  return LISTENING_MODELS[0];
}

/**
 * Переводчики расшифровки. Первый — по умолчанию.
 *
 * ЗДЕСЬ ТОЛЬКО `qwen-mt-*`, и это не случайность: обычную чат-модель надо
 * уговаривать ответить строго переводом и ничем больше, а переводчик ничего
 * другого и не умеет. Список тот же, что видит игрок в настройках
 * (lib/data/judge_models.dart); это сторожит тест.
 */
const TRANSLATION_MODELS = [
  "qwen-mt-flash",
  "qwen-mt-lite",
  "qwen-mt-turbo",
  "qwen-mt-plus",
] as const;

function translationModel(chosen?: string | null): string {
  const wanted = (chosen ?? "").trim();
  if ((TRANSLATION_MODELS as readonly string[]).includes(wanted)) return wanted;
  const fromEnv = Deno.env.get("TRANSCRIBE_TRANSLATE_MODEL");
  if (fromEnv && (TRANSLATION_MODELS as readonly string[]).includes(fromEnv)) return fromEnv;
  return TRANSLATION_MODELS[0];
}

/** Расширение файла: по нему провайдер определяет формат записи. */
function extensionOf(storagePath: string): string {
  const dot = storagePath.lastIndexOf(".");
  if (dot < 0 || dot === storagePath.length - 1) return "mp3";
  const ext = storagePath.slice(dot + 1).toLowerCase();
  return ext.length > 5 ? "mp3" : ext;
}

/** Куда ляжет разбор. Рядом с записью — по тому же праву, что и она. */
function resultPathFor(storagePath: string): string {
  const dot = storagePath.lastIndexOf(".");
  return `${dot > 0 ? storagePath.slice(0, dot) : storagePath}.result.json`;
}

/**
 * Цена разбора: одна единица за каждые начатые полминуты.
 *
 * ТА ЖЕ ФОРМУЛА ПОВТОРЕНА НА КЛИЕНТЕ (lib/data/library_track.dart).
 * Дублирование вынужденное: там её показывают ДО подтверждения, здесь
 * списывают. Разойдясь, они покажут одну цену, а возьмут другую.
 */
function energyCost(durationMs: number): number {
  if (!Number.isFinite(durationMs) || durationMs <= 0) return 1;
  return Math.max(1, Math.ceil(durationMs / 30_000));
}

const LANGUAGE_NAMES: Record<string, string> = {
  en: "English",
  ru: "Russian",
  es: "Spanish",
  pl: "Polish",
  de: "German",
  fr: "French",
  it: "Italian",
  pt: "Portuguese",
  tr: "Turkish",
  uk: "Ukrainian",
};

function languageName(code: string): string {
  return LANGUAGE_NAMES[code] ?? code;
}

function prompt(translateTo: string): string {
  const target = languageName(translateTo);
  return [
    "Transcribe this audio and translate it, WORD BY WORD.",
    "",
    "Answer with JSON only — no prose, no markdown fence:",
    '{"language":"<ISO code of the audio>","lines":[[{"w":"","t":"","start":0}]]}',
    "",
    "Rules:",
    `1. "w" is ONE word exactly as sung or spoken, in the original language.`,
    `2. "t" is that single word translated into ${target}. Translate the word`,
    "   as it is used in this line, not its dictionary entry. If the word has",
    "   no separate translation (an article, an auxiliary), use an empty string.",
    '3. "start" is milliseconds from the beginning of the audio, increasing.',
    "   Do not add any other field: every extra character is time we do not have.",
    "4. Split into lines the way they are actually sung or said — a line is",
    "   one breath or one phrase, not a fixed number of words.",
    "5. Never merge two words into one object and never split one word in two:",
    "   the pair w/t must stay aligned for the whole recording.",
    "6. Transcribe only what is audible. Do not invent words to fill silence.",
  ].join("\n");
}

/** Слово ли это. Имена полей берём шире, чем просили: модель их путает. */
function asWord(node: unknown): Record<string, unknown> | null {
  if (!node || typeof node !== "object" || Array.isArray(node)) return null;
  const o = node as Record<string, unknown>;
  const text = o.w ?? o.word ?? o.text;
  if (typeof text !== "string" || text.trim().length === 0) return null;
  const translation = o.t ?? o.translation ?? o.tr;
  return {
    w: text.trim(),
    t: typeof translation === "string" ? translation.trim() : "",
    start: Number(o.start ?? o.begin ?? o.from ?? 0) || 0,
    end: Number(o.end ?? o.stop ?? o.to ?? 0) || 0,
  };
}

/**
 * Раскладывает ЧТО УГОДНО в строки из слов.
 *
 * ЗАЧЕМ. Формат ответа задан в запросе, но задан — не значит соблюдён.
 * Живой разбор вернул строки на уровень вложеннее просимого, и приложение
 * упало на приведении типа: «type 'List<dynamic>' is not a subtype of type
 * 'Map<dynamic, dynamic>'». Модель к тому моменту отработала, запись была
 * разобрана, энергия списана — и всё это выброшено из-за лишней пары
 * скобок. Такой ответ надо разбирать, а не отвергать.
 *
 * Правило простое: массив, все элементы которого — слова, это СТРОКА;
 * любой другой массив — СПИСОК строк, и в него надо спуститься. Объект,
 * который сам не слово, отдаёт свои массивы (так ловится {"words": […]}).
 */
function linesOf(node: unknown): Record<string, unknown>[][] {
  if (Array.isArray(node)) {
    if (node.length === 0) return [];
    const words = node.map(asWord);
    if (words.every((w) => w !== null)) {
      return [words as Record<string, unknown>[]];
    }
    return node.flatMap(linesOf);
  }
  const single = asWord(node);
  if (single) return [[single]];
  if (node && typeof node === "object") {
    return Object.values(node as Record<string, unknown>)
      .filter(Array.isArray)
      .flatMap(linesOf);
  }
  return [];
}

/**
 * Строка длиной во всю запись — это сломанный экран.
 *
 * Экран показывает ОДНУ строку за раз и ужимает её по ширине; строка из
 * двухсот слов превратится в нечитаемую полоску. Так выглядит ответ, в
 * котором модель не разбила запись на строки вовсе, — режем сами, по самым
 * длинным паузам, а если пауз нет, то поровну.
 */
const MAX_WORDS_PER_LINE = 12;

/**
 * Достраивает конец каждого слова по началу следующего.
 *
 * Поле `end` у модели больше НЕ ПРОСИМ: на запись в три с половиной минуты
 * это тысячи лишних символов, а генерация — единственное, что здесьдолго.
 * Конец слова всё равно известен точно: это начало следующего. Последнему
 * даём полсекунды — дальше него подсвечивать нечего.
 */
function fillEnds(line: Record<string, unknown>[]): Record<string, unknown>[] {
  for (let i = 0; i < line.length; i++) {
    const start = Number(line[i].start) || 0;
    const known = Number(line[i].end) || 0;
    const next = i + 1 < line.length ? Number(line[i + 1].start) || 0 : 0;
    line[i].end = known > start ? known : (next > start ? next : start + 500);
  }
  return line;
}

function splitLong(line: Record<string, unknown>[]): Record<string, unknown>[][] {
  if (line.length <= MAX_WORDS_PER_LINE) return [line];
  const out: Record<string, unknown>[][] = [];
  let current: Record<string, unknown>[] = [];
  for (let i = 0; i < line.length; i++) {
    current.push(line[i]);
    const gap = i + 1 < line.length
      ? Number(line[i + 1].start) - Number(line[i].end)
      : 0;
    const enough = current.length >= MAX_WORDS_PER_LINE ||
      (current.length >= 4 && gap >= 600);
    if (enough) {
      out.push(current);
      current = [];
    }
  }
  if (current.length > 0) out.push(current);
  return out;
}


// ═══════════════════════════════════════════════════════════════════════
// РАСПОЗНАВАТЕЛЬ: ВРЕМЯ ИЗМЕРЕННОЕ, А НЕ СОЧИНЁННОЕ
//
// Мультимодальная модель делает всё одним вызовом — и расшифровку, и
// перевод, и время. Первая живая проверка показала, чего это стоит:
// субтитры сильно разъехались со звуком. Время она не измеряет, а
// придумывает правдоподобные числа, и заметно это только на слух.
//
// Настоящий распознаватель время измеряет. Платой за это идёт второй вызов:
// перевода он не знает, и слова приходится переводить отдельно, текстовой
// моделью. Что лучше — решает не рассуждение, а сравнение на живых записях,
// ради того выбор модели и вынесен в настройки.
// ═══════════════════════════════════════════════════════════════════════

interface Timed {
  text: string;
  start: number;
  end: number;
}

function firstString(o: Record<string, unknown>, keys: string[]): string | null {
  for (const k of keys) {
    const v = o[k];
    if (typeof v === "string" && v.trim().length > 0) return v.trim();
  }
  return null;
}

function firstNumber(o: Record<string, unknown>, keys: string[]): number | null {
  for (const k of keys) {
    const v = o[k];
    if (typeof v === "number" && Number.isFinite(v)) return v;
    if (typeof v === "string") {
      const parsed = Number(v);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return null;
}

/**
 * Достаёт из ответа распознавателя САМЫЙ ГЛУБОКИЙ уровень разметки.
 *
 * Провайдер кладёт её вложенно: у фразы есть своё время, а внутри — слова
 * со своим. Слова точнее, поэтому спускаемся до упора и берём то, что
 * лежит глубже всего. Имена полей у разных семейств разные, и угадывать их
 * по одному мы уже пробовали — здесь перечислены все встречавшиеся.
 */
function timedItems(node: unknown): Timed[] {
  if (Array.isArray(node)) return node.flatMap(timedItems);
  if (!node || typeof node !== "object") return [];
  const o = node as Record<string, unknown>;

  const deeper = Object.values(o).flatMap(timedItems);
  if (deeper.length > 0) return deeper;

  const text = firstString(o, ["text", "word", "w", "punctuated_text"]);
  const start = firstNumber(o, ["begin_time", "start_time", "beginTime", "start", "begin"]);
  if (text === null || start === null) return [];
  const end = firstNumber(o, ["end_time", "stop_time", "endTime", "end", "stop"]) ?? start;
  return [{ text, start, end: end > start ? end : start }];
}

/**
 * Фразу режет на слова, раскладывая её время по буквам.
 *
 * ЭТО ПРИБЛИЖЕНИЕ, И ОНО ЧЕСТНОЕ. Когда распознаватель отдал время только
 * фразам, начало и конец каждой — измеренные, настоящие; выдумано лишь то,
 * как время распределено ВНУТРИ фразы. Это несравнимо ближе к правде, чем
 * придуманные с нуля числа, и промах не копится: следующая фраза снова
 * встаёт на своё измеренное место.
 */
function wordsOfPhrase(item: Timed): Timed[] {
  const parts = item.text.split(/\s+/).filter((p) => p.length > 0);
  if (parts.length <= 1) return [item];
  const span = Math.max(1, item.end - item.start);
  const letters = parts.reduce((sum, p) => sum + p.length, 0) || parts.length;
  const out: Timed[] = [];
  let at = item.start;
  for (const part of parts) {
    const share = Math.round((span * part.length) / letters);
    out.push({ text: part, start: at, end: at + share });
    at += share;
  }
  out[out.length - 1].end = item.end;
  return out;
}

/**
 * Переводит СТРОКИ, каждую своим вызовом.
 *
 * ПОСТРОЧНО, А НЕ СПИСКОМ. Список пришлось бы просить у модели структурой, и
 * тогда возвращается ровно та опасность, ради которой всё начиналось с
 * одного вызова: перевод, поехавший относительно оригинала, разъезжается
 * молча и до конца записи. Одна строка на вызов — и сопоставлять нечего:
 * что отдали, то и получили.
 *
 * ПЕРЕВОДЧИКАМ НЕ ДАЮТ ИНСТРУКЦИЙ. `qwen-mt-*` — не собеседники: им дают
 * текст, они отдают текст. Поэтому системной части нет вовсе, а в
 * пользовательской — только сама строка и язык.
 *
 * ВОСЕМЬ ВЫЗОВОВ РАЗОМ. Строк в песне под сотню, и последовательно это
 * минуты — больше, чем нам вообще отпущено. Больше восьми одновременно не
 * пускаем: провайдер за это отвечает отказами по частоте запросов.
 */
async function translateLines(
  lines: string[],
  translateTo: string,
  model: string,
  budgetMs: number,
): Promise<string[]> {
  const target = languageName(translateTo);
  const out = new Array<string>(lines.length).fill("");
  const started = Date.now();
  const left = () => budgetMs - (Date.now() - started);
  const LANES = 8;

  let next = 0;
  const lane = async () => {
    for (;;) {
      const i = next++;
      if (i >= lines.length) return;
      const budget = left();
      if (budget < 6_000) return; // не успеем — остаток останется без перевода
      const answer = await requestQwen(
        "",
        [{ type: "text", text: `Translate into ${target}:\n${lines[i]}` }],
        budget,
        model,
        { temperature: 0, timeoutMs: budget },
      );
      if ("error" in answer) continue;
      out[i] = answer.raw.trim();
    }
  };

  await Promise.all(Array.from({ length: Math.min(LANES, lines.length) }, lane));
  return out;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  if (serviceKey.length === 0 || url.length === 0) {
    return json({ error: "функция не настроена" }, 500);
  }

  // Кто просит. Без этого списывать энергию не с кого.
  const authorization = req.headers.get("Authorization") ?? "";
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: auth } = await asUser.auth.getUser();
  const userId = auth?.user?.id;
  if (!userId) return json({ error: "не авторизован" }, 401);

  let body: { storagePath?: string; durationMs?: number; translateTo?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "не разобрал запрос" }, 400);
  }

  const storagePath = (body.storagePath ?? "").trim();
  const durationMs = Number(body.durationMs ?? 0);
  const translateTo = (body.translateTo ?? "").trim();
  if (storagePath.length === 0) return json({ error: "нет записи" }, 400);
  // ЧУЖУЮ ЗАПИСЬ РАЗОБРАТЬ НЕЛЬЗЯ. Путь приходит от клиента, и без этой
  // проверки любой, знающий чужой путь, оплатил бы своей энергией разбор
  // чужого файла — и получил бы его расшифровку.
  if (!storagePath.startsWith(`tracks/${userId}/`)) {
    return json({ error: "чужая запись" }, 403);
  }
  if (translateTo.length === 0) return json({ error: "не указан язык перевода" }, 400);
  if (durationMs > MAX_DURATION_MS) {
    const minutes = Math.round(MAX_DURATION_MS / 60_000);
    return json({ error: `запись длиннее ${minutes} минут — разбор не успеет` }, 400);
  }

  const key = judgeKey();
  if (!key) {
    return json(
      { error: "нет ключа модели: npx supabase secrets set OMNI_API_KEY=<ключ qwencloud>" },
      500,
    );
  }

  const cost = energyCost(durationMs);

  // ХВАТАЕТ ЛИ ЭНЕРГИИ — СПРАШИВАЕМ ЗДЕСЬ, А НЕ ВЕРИМ ПЛАШКЕ НА КЛИЕНТЕ.
  //
  // spend_energy при нехватке НЕ ПАДАЕТ: она списывает сколько есть и
  // возвращает остаток — так задумано для боевого воркера, который берёт
  // деньги уже после ответа провайдера. Здесь же плата идёт вперёд, и без
  // этой проверки единственным заслоном оставалась бы плашка, нарисованная
  // по кошельку, который мог устареть, пока игрок выбирал файл. То есть
  // разбор за полцены — и никакого отказа.
  //
  // sync_wallet зовём ОТ ИМЕНИ ИГРОКА: она сама досчитывает восстановленную
  // энергию, и прочитать колонку напрямую значило бы отказать тому, у кого
  // запас уже натикал.
  const { data: wallet, error: walletError } = await asUser.rpc("sync_wallet");
  if (walletError) {
    return json({ error: `не удалось прочитать энергию: ${walletError.message}` }, 500);
  }
  const energyLeft = Number((wallet as Record<string, unknown> | null)?.energy_current ?? 0);
  if (energyLeft < cost) {
    return json(
      { error: `нужно ${cost} энергии, а есть ${energyLeft}`, energy_left: energyLeft },
      402,
    );
  }

  // Ссылка кончается расширением файла — иначе провайдер не определит
  // формат (см. _shared/audioLink.ts и функцию asr-audio).
  //
  // СОБИРАЕТСЯ ДО СПИСАНИЯ. Не собралась — значит модель мы даже не звали, и
  // брать за это плату не за что: провайдеру мы ничего не должны.
  let audioUrl: string;
  try {
    audioUrl = await audioUrlFor(storagePath, url, serviceKey);
  } catch (e) {
    return json({ error: `не собралась ссылка на запись: ${e}` }, 500);
  }

  // ЭНЕРГИЯ СПИСЫВАЕТСЯ ДО ВЫЗОВА. Модель берёт деньги за попытку, а не за
  // удачу: списав после, мы дарили бы каждый неудачный разбор.
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: left, error: spendError } = await admin.rpc("spend_energy", {
    p_user_id: userId,
    p_amount: cost,
    p_reason: "transcribe-track",
  });
  if (spendError) return json({ error: `не удалось списать энергию: ${spendError.message}` }, 500);

  // ═══ ОТВЕЧАЕМ СРАЗУ, РАЗБИРАЕМ В ФОНЕ ═══
  //
  // Держать запрос открытым всё время разбора нельзя: Edge Function живёт
  // ограниченное время, и когда оно наступает, шлюз обрывает запрос сам —
  // приложение получает «сервер ответил 504» без причины и с уже списанной
  // энергией. Разбор записи в минуты в такой срок не помещается в принципе.
  //
  // Поэтому ответ здесь — подтверждение приёма, а не результат. Результат
  // ложится в хранилище рядом с записью, и приложение забирает его оттуда:
  // права на эту папку у него уже есть (миграция 0052), и ждать ему больше
  // нечего — файл появится или не появится.
  // МОДЕЛЬ БЕРЁМ ИЗ ПРОФИЛЯ, А НЕ ИЗ ЗАПРОСА. Так же, как боевой воркер
  // берёт asr_model/llm_model: клиент записывает выбор себе в профиль, а
  // называть модель в запросе к платному провайдеру ему не дают.
  const { data: profile } = await admin
    .from("users")
    .select("listening_model, translation_model")
    .eq("id", userId)
    .maybeSingle();
  const model = listeningModel((profile?.listening_model as string | null) ?? null);
  const translator = translationModel((profile?.translation_model as string | null) ?? null);

  const resultPath = resultPathFor(storagePath);

  // Фоновой задаче база не нужна — ей нужен ровно один способ сохранить
  // результат. Замыкание здесь и потому, что тип клиента Supabase выводится
  // только на месте создания.
  const save = async (body: unknown) => {
    try {
      await admin.storage.from(BUCKET).upload(
        resultPath,
        new Blob([JSON.stringify(body)], { type: "application/json" }),
        { contentType: "application/json", upsert: true },
      );
    } catch (e) {
      console.error("transcribe-track: результат не записался", e);
    }
  };

  const work = transcribe({
    save,
    audioUrl,
    translateTo,
    cost,
    left,
    model,
    translator,
    format: extensionOf(storagePath),
  });
  if (typeof EdgeRuntime !== "undefined") {
    EdgeRuntime.waitUntil(work);
  } else {
    // Локальный запуск без рантайма Supabase — иначе задача оборвётся
    // вместе с ответом.
    await work;
  }

  return json(
    { accepted: true, result_path: resultPath, model, translator, energy_spent: cost, energy_left: left },
    202,
  );
});

/**
 * Разбор и запись результата. НИКОГДА НЕ БРОСАЕТ и всегда что-то пишет.
 *
 * Молчание здесь неотличимо от «ещё думаю»: приложение будет ждать файл,
 * которого не будет, до собственного срока. Поэтому отказ — тоже результат,
 * и он ложится туда же.
 */
async function transcribe(job: {
  save: (body: unknown) => Promise<void>;
  audioUrl: string;
  translateTo: string;
  cost: number;
  left: unknown;
  model: string;
  translator: string;
  format: string;
}): Promise<void> {
  const put = job.save;
  try {
    if (asrFamily(job.model) !== "omni") {
      await transcribeByAsr(job, put);
      return;
    }
    const answer = await requestQwen(
      "",
      [
        { type: "input_audio", input_audio: { data: job.audioUrl } },
        { type: "text", text: prompt(job.translateTo) },
      ],
      TIMEOUT_MS - WRITE_RESERVE_MS,
      job.model,
      { audio: true, temperature: 0, timeoutMs: TIMEOUT_MS - WRITE_RESERVE_MS },
    );

    if ("error" in answer) {
      await put({ error: answer.error, energy_left: job.left });
      return;
    }

    const parsed = parseJson(answer.raw);
    // Разбираем ответ КАК ПОЛУЧИЛОСЬ, а не как просили: к этому месту модель
    // уже отработала и энергия уже списана, так что отвергать разбор из-за
    // лишней пары скобок — значит брать деньги и выбрасывать товар.
    const lines = linesOf(parsed?.lines ?? parsed).map(fillEnds).flatMap(splitLong);
    if (lines.length === 0) {
      await put({
        error: "модель вернула не разбор",
        sample: answer.raw.slice(0, 300),
        energy_left: job.left,
      });
      return;
    }

    await put({
      language: typeof parsed?.language === "string" ? parsed.language : "",
      translation: job.translateTo,
      lines,
      energy_spent: job.cost,
      energy_left: job.left,
    });
  } catch (e) {
    await put({ error: `сбой разбора: ${e}`, energy_left: job.left });
  }
}

/**
 * Путь распознавателя: сначала разметка по времени, потом перевод.
 *
 * Два вызова вместо одного, и это осознанная плата. Первый измеряет время —
 * ровно то, чего у мультимодальной модели нет. Второй переводит СПИСОК СЛОВ
 * по номерам, и рассогласоваться там нечему: длины сверяются, а при
 * несовпадении перевод не берётся вовсе.
 */
async function transcribeByAsr(
  job: {
    audioUrl: string;
    translateTo: string;
    cost: number;
    left: unknown;
    model: string;
    translator: string;
    format: string;
  },
  put: (body: unknown) => Promise<void>,
): Promise<void> {
  const started = Date.now();
  const budget = TIMEOUT_MS - WRITE_RESERVE_MS;
  const heard = await nativeTranscribe(job.model, job.audioUrl, job.format, budget);
  if ("error" in heard) {
    await put({ error: `распознавание не прошло: ${heard.error}`, energy_left: job.left });
    return;
  }

  let parsed: unknown = null;
  try {
    parsed = JSON.parse(heard.body);
  } catch {
    parsed = null;
  }
  const items = timedItems(parsed);
  if (items.length === 0) {
    // РАЗМЕТКИ НЕТ — И ЭТО НАДО ПОКАЗАТЬ, А НЕ УГАДЫВАТЬ. Кусок ответа
    // отвечает на единственный вопрос: где у этой модели лежит время.
    await put({
      error: "распознаватель не вернул разметку по времени",
      sample: heard.body.slice(0, 400),
      energy_left: job.left,
    });
    return;
  }

  const words = items.flatMap(wordsOfPhrase).map((w) => ({
    w: w.text,
    t: "",
    start: w.start,
    end: w.end,
  }));
  const lines = splitLong(fillEnds(words));

  // ПЕРЕВОДИМ УЖЕ РАЗБИТОЕ НА СТРОКИ. Строка — это то, что игрок читает
  // справа целиком; переводить её кусками значило бы показать ему склейку
  // из обрывков.
  const translations = await translateLines(
    lines.map((line) => line.map((w) => w.w).join(" ")),
    job.translateTo,
    job.translator,
    budget - (Date.now() - started),
  );

  await put({
    language: "",
    translation: job.translateTo,
    lines: lines.map((line, i) => ({ t: translations[i] ?? "", w: line })),
    model: job.model,
    translator: job.translator,
    energy_spent: job.cost,
    energy_left: job.left,
  });
}
