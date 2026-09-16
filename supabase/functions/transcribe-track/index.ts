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

/** Модель. Та же, что уже разбирает записи в бою. */
const MODEL = Deno.env.get("OMNI_TRANSCRIBE_MODEL") ?? "qwen3-omni-flash";

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
 * Свой бюджет вызова, а не общий OMNI_TIMEOUT_MS.
 *
 * Судья разбирает одну фразу и укладывается в полторы минуты; здесь модель
 * слушает запись целиком. Связав их одним секретом, мы получили бы ручку,
 * которая чинит одно и ломает другое молча.
 */
const TIMEOUT_MS = Number(Deno.env.get("TRANSCRIBE_TIMEOUT_MS") ?? "240000");

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
    '{"language":"<ISO code of the audio>","lines":[[{"w":"","t":"","start":0,"end":0}]]}',
    "",
    "Rules:",
    `1. "w" is ONE word exactly as sung or spoken, in the original language.`,
    `2. "t" is that single word translated into ${target}. Translate the word`,
    "   as it is used in this line, not its dictionary entry. If the word has",
    "   no separate translation (an article, an auxiliary), use an empty string.",
    '3. "start" and "end" are milliseconds from the beginning of the audio.',
    "   They must increase and must not overlap between words.",
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

  const answer = await requestQwen(
    "",
    [
      { type: "input_audio", input_audio: { data: audioUrl } },
      { type: "text", text: prompt(translateTo) },
    ],
    TIMEOUT_MS,
    MODEL,
    { audio: true, temperature: 0, timeoutMs: TIMEOUT_MS },
  );

  if ("error" in answer) {
    return json({ error: answer.error, energy_left: left }, 502);
  }

  const parsed = parseJson(answer.raw);
  // Разбираем ответ КАК ПОЛУЧИЛОСЬ, а не как просили: к этому месту модель
  // уже отработала и энергия уже списана, так что отвергать разбор из-за
  // лишней пары скобок — значит брать деньги и выбрасывать товар.
  const lines = linesOf(parsed?.lines ?? parsed).flatMap(splitLong);
  if (lines.length === 0) {
    return json(
      { error: "модель вернула не разбор", sample: answer.raw.slice(0, 300), energy_left: left },
      502,
    );
  }

  return json({
    language: typeof parsed?.language === "string" ? parsed.language : "",
    translation: translateTo,
    lines,
    energy_spent: cost,
    energy_left: left,
  });
});
