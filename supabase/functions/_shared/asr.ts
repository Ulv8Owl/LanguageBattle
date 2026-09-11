/**
 * Распознавание речи — первый шаг двухшагового пути этой ветки.
 *
 * ЗАЧЕМ ДВА ШАГА, КОГДА ОДИН УЖЕ РАБОТАЕТ. Ради цены. Мультимодальной
 * модели на вход идёт аудио, и платим мы за аудио; здесь за аудио платит
 * только распознаватель — модель заточенная ровно под одно дело, — а судья
 * получает текст, который стоит копейки.
 *
 * ЧТО ТЕРЯЕТСЯ, СКАЗАНО ЧЕСТНО. Всё, что слышно только в звуке: произношение,
 * ударение, проглоченное окончание, оборванное слово. Хуже того,
 * распознаватель ПРИГЛАЖИВАЕТ речь — расставляет знаки препинания, пишет
 * заглавные буквы, а иногда правит и грамматику. Поэтому «ошибок не найдено»
 * на этом пути значит «ошибок не осталось в тексте», а не «игрок сказал
 * верно».
 *
 * ═══ ПОЧЕМУ ЗДЕСЬ ТРИ СХЕМЫ ВЫЗОВА, А НЕ ОДНА ═══
 *
 * Потому что у провайдера их и правда три, и модели распознавания разложены
 * по ним не по нашему вкусу. Раньше на этом месте стояла лесенка из трёх
 * попыток подряд — она была ЧИСТЫМ УГАДЫВАНИЕМ и все пять кругов проверок
 * провалила. Документация провайдера отвечает на это прямо, и вот ответ:
 *
 *   * `format` и `sample_rate` у своей схемы провайдера лежат в
 *     `parameters` — РЯДОМ с `input`, а не внутри `input_audio`. Мы клали
 *     их внутрь, поэтому в ответ и приходило «format is empty»: поле
 *     отправлялось, но не туда, где его читают. Это и есть причина бага,
 *     одна на все пять кругов;
 *   * содержимое сообщения у `qwen-audio-3.0-*` — `{"type":"input_audio",
 *     "input_audio":{"data": …}}`, а короткая форма `{"audio": …}` это
 *     схема другого семейства (`qwen3-asr-flash`). Мы слали короткую не той
 *     модели;
 *   * текст ответа своей схемы лежит в `output.output.sentence.text`, а НЕ
 *     в `output.choices[].message.content`, куда мы смотрели;
 *   * `fun-asr-mtl`, `fun-asr` и все `*-filetrans` в оба этих пути не
 *     ходят вовсе: им нужен ОТДЕЛЬНЫЙ асинхронный путь распознавания файлов
 *     (`/api/v1/services/audio/asr/transcription` с заголовком
 *     `X-DashScope-Async: enable` и опросом задачи). Отсюда и честный
 *     ответ «Unsupported model for OpenAI compatibility mode». Из списка
 *     моделей они убраны: звать их тем путём, которого у них нет, значит
 *     держать игроку сломанную кнопку.
 *
 * Поэтому вместо лесенки — одна документированная схема на семейство. Две
 * попытки внутри семейства остаются, но это не угадывание: `data` по
 * документации принимает И ссылку, И вложенное base64, а ссылка дешевле —
 * её и пробуем первой.
 *
 * КАКАЯ СХЕМА СРАБОТАЛА, ВИДНО В ОТЛАДКЕ ЗАПИСИ (`asr.shape`), и неудачные
 * попытки лежат там же со своими ответами.
 */

import { base64, judgeBaseUrl, judgeKey, requestQwen } from "./review.ts";

/**
 * Модели для первого шага — превратить речь в текст.
 *
 * ПЕРВОЙ СТОИТ МУЛЬТИМОДАЛЬНАЯ, И ЭТО НЕ ОПЕЧАТКА. Она не заточена под
 * распознавание и стоит дороже — зато она РАБОТАЕТ на живых записях уже
 * месяц. Специальные распознаватели ниже теперь зовутся по документации, а
 * не по догадке, но проверены они пока только на форме запроса; по
 * умолчанию ветка должна работать, а не проверяться.
 *
 * ЧЕГО В СПИСКЕ НЕТ И ПОЧЕМУ. `fun-asr-mtl`, `fun-asr` и `*-filetrans`
 * живут на отдельном асинхронном пути распознавания файлов — там задача
 * ставится в очередь и опрашивается, это другой endpoint и другой сценарий.
 * Пока мы туда не ходим, держать их в списке значит предлагать игроку
 * кнопку, которая гарантированно ответит отказом.
 */
export const ASR_MODELS = [
  // Проверено на живых записях — та же форма вызова, что и на ветке Omni.
  "qwen3-omni-flash",
  "qwen3.5-omni-flash",
  // Своя схема провайдера: параметры звука в `parameters`.
  "qwen-audio-3.0-asr-flash",
  "fun-asr-flash-2026-06-15",
  // OpenAI-совместимый режим, но со своими `asr_options` и БЕЗ `format`.
  "qwen3-asr-flash",
] as const;

export const DEFAULT_ASR_MODEL = ASR_MODELS[0];

/** Выбор игрока сильнее окружения; незнакомое значение — модель по умолчанию. */
export function asrModel(chosen?: string | null): string {
  const wanted = (chosen ?? "").trim();
  if ((ASR_MODELS as readonly string[]).includes(wanted)) return wanted;
  const fromEnv = Deno.env.get("ASR_MODEL");
  if (fromEnv && (ASR_MODELS as readonly string[]).includes(fromEnv)) return fromEnv;
  return DEFAULT_ASR_MODEL;
}

/**
 * Частота записи, которую провайдер ждёт числом рядом с форматом.
 *
 * Здесь она константой, а не вычисляется из файла, потому что приложение
 * пишет ровно один формат: WAV PCM 16 бит, 16 кГц, моно
 * (`lib/core/audio_format.dart`). Начнём писать иначе — чинить придётся оба
 * места сразу, и пусть это будет заметно.
 */
const SAMPLE_RATE = "16000";

/** К какому семейству относится модель — от этого зависит вся форма вызова. */
export type AsrFamily = "omni" | "compat-asr" | "native-asr";

/**
 * Семейство модели по её имени.
 *
 * Открыто наружу ради проверки: перепутанное семейство это не падение, а
 * отказ провайдера на живой записи — то есть баг, который виден только
 * игроку.
 */
export function asrFamily(model: string): AsrFamily {
  if (model.includes("omni")) return "omni";
  if (model.startsWith("qwen3-asr")) return "compat-asr";
  return "native-asr";
}

export interface AsrResult {
  /** Что распознано. Пустая строка — речи в записи не нашлось. */
  text: string;
  /** Сбой вызова. Пусто — вызов прошёл, даже если текста нет. */
  error?: string;
  debug: Record<string, unknown>;
}

/** Одна попытка вызова: как звали и что ответили. */
interface Attempt {
  shape: string;
  ok: boolean;
  detail: string;
}

/**
 * Расшифровывает запись. НИКОГДА НЕ БРОСАЕТ.
 *
 * Сбой распознавания — это `error`, а не исключение: воркер должен уметь
 * закрыть задачу честным «модель не ответила», иначе она повиснет в
 * 'processing', а игрок будет ждать результат, которого не будет.
 *
 * ЯЗЫК НЕ ПОДСКАЗЫВАЕМ НАМЕРЕННО. Распознаватель определяет его сам, и это
 * не лень, а механика проверки «не тот язык»: сказав по-русски, игрок
 * получит русский текст, и судья это назовёт. Подскажи мы английский —
 * распознаватель услышал бы английский в чём угодно.
 */
export async function transcribe(req: {
  /** Подписанная ссылка на запись. Ею зовём первой — она дешевле вложения. */
  audioUrl?: string | null;
  audio: Uint8Array;
  audioFormat: string;
  model?: string | null;
  budgetMs: number;
}): Promise<AsrResult> {
  const started = Date.now();
  const model = asrModel(req.model);
  const family = asrFamily(model);
  const url = (req.audioUrl ?? "").trim();
  const attempts: Attempt[] = [];
  const left = () => req.budgetMs - (Date.now() - started);

  const debug = (extra: Record<string, unknown> = {}) => ({
    provider: "asr",
    model,
    family,
    model_requested: (req.model ?? "").trim().length > 0 ? req.model : null,
    base_url: judgeBaseUrl(),
    audio_bytes: req.audio.byteLength,
    audio_format: req.audioFormat,
    has_url: url.length > 0,
    // Ссылку показываем целиком НАМЕРЕННО: открыв её в браузере, можно за
    // секунду отличить «провайдер не понял ссылку» от «ссылка не работает».
    // Токен в ней живёт десять минут и открывает одну эту запись.
    audio_url: url.length > 0 ? url : null,
    attempts,
    ms: Date.now() - started,
    ...extra,
  });

  if (req.audio.byteLength === 0 && url.length === 0) {
    return { text: "", error: "запись пуста", debug: debug({ status: "failed" }) };
  }

  // Вложение — это то же аудио, только внутри запроса. Считаем его один раз:
  // base64 от полумегабайта не бесплатен, а нужен он в двух семействах.
  const inline = () => `data:audio/${req.audioFormat};base64,${base64(req.audio)}`;

  const shapes: { name: string; run: () => Promise<{ raw: string } | { error: string }> }[] = [];

  if (family === "omni") {
    // Форма известна и проверена месяцем игры: вложение плюс текстовая
    // часть, обычный чат. Пробовать что-то ещё тут незачем.
    if (req.audio.byteLength > 0) {
      shapes.push({
        name: "compat-inline",
        run: () =>
          requestQwen(
            "You are a speech transcriber. Write down exactly what is said and nothing else.",
            [
              audioPart(req.audio, req.audioFormat),
              { type: "text", text: "Transcribe this recording." },
            ],
            left(),
            model,
            { audio: true, temperature: 0 },
          ),
      });
    }
  } else if (family === "compat-asr") {
    // Совместимый режим, но тело своё: ни `format`, ни системной части —
    // вместо них `asr_options`. Лишние поля этот путь отвергает.
    if (url.length > 0) {
      shapes.push({ name: "compat-asr-url", run: () => compatAsr(model, url, left()) });
    }
    if (req.audio.byteLength > 0) {
      shapes.push({ name: "compat-asr-inline", run: () => compatAsr(model, inline(), left()) });
    }
  } else {
    // Своя схема провайдера: параметры звука — рядом с `input`.
    if (url.length > 0) {
      shapes.push({
        name: "native-url",
        run: () => nativeTranscribe(model, url, req.audioFormat, left()),
      });
    }
    if (req.audio.byteLength > 0) {
      shapes.push({
        name: "native-inline",
        run: () => nativeTranscribe(model, inline(), req.audioFormat, left()),
      });
    }
  }

  for (const shape of shapes) {
    if (left() < 5_000) {
      attempts.push({ shape: shape.name, ok: false, detail: "не осталось времени" });
      break;
    }
    const answer = await shape.run();
    if ("error" in answer) {
      attempts.push({ shape: shape.name, ok: false, detail: answer.error.slice(0, 300) });
      continue;
    }
    const text = cleanTranscript(answer.raw);
    attempts.push({ shape: shape.name, ok: true, detail: `${text.length} символов` });
    return {
      text,
      debug: debug({
        status: text.length > 0 ? "ok" : "empty",
        shape: shape.name,
        // Сырой ответ обрезан: спорить о расшифровке можно только по нему, а
        // раздувать строку в базе незачем.
        raw: answer.raw.slice(0, 600),
      }),
    };
  }

  // Ни одна форма не прошла. В текст ошибки идут ВСЕ попытки: по одной
  // последней не понять, отказал ли провайдер модели или нашему запросу.
  const reason = `${model} (${req.audioFormat}, ${req.audio.byteLength} Б): ` +
    attempts.map((a) => `[${a.shape}] ${a.detail}`).join(" | ");
  return { text: "", error: reason, debug: debug({ status: "failed" }) };
}

/**
 * Своя схема DashScope, не OpenAI-совместимая.
 *
 * ЗДЕСЬ И ЖИЛ БАГ «format is empty». Формат и частоту провайдер читает из
 * `parameters` — рядом с `input`, а не внутри `input_audio`, куда мы их
 * клали пять кругов подряд. Поле отправлялось, ответ был честным: там, где
 * его читают, оно действительно пустое.
 *
 * `data` принимает И ссылку, И вложение `data:audio/wav;base64,…` —
 * поэтому параметр здесь называется `audio`, а не `audioUrl`.
 */
async function nativeTranscribe(
  model: string,
  audio: string,
  format: string,
  budgetMs: number,
): Promise<{ raw: string } | { error: string }> {
  const key = judgeKey();
  if (!key) return { error: "нет ключа модели" };
  // Хост берём из того же адреса, что и совместимый путь: менять их порознь
  // значит однажды разослать запросы по двум разным регионам.
  const host = judgeBaseUrl().replace(/\/compatible-mode\/v1\/?$/, "");
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(5_000, budgetMs));
  try {
    const res = await fetch(`${host}/api/v1/services/aigc/multimodal-generation/generation`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${key}`,
        // Ответ целиком, а не потоком: разбирать поток тут нечего, а без
        // заголовка часть моделей отвечает событиями.
        "X-DashScope-SSE": "disable",
      },
      body: JSON.stringify({
        model,
        input: {
          messages: [
            { role: "user", content: [{ type: "input_audio", input_audio: { data: audio } }] },
          ],
        },
        // Вот ровно то место, которого не хватало.
        parameters: { format, sample_rate: SAMPLE_RATE },
      }),
      signal: controller.signal,
    });
    const body = await res.text();
    if (!res.ok) return { error: `HTTP ${res.status}: ${body.slice(0, 400)}` };
    const text = nativeText(body);
    if (text === null) return { error: `ответ без текста: ${body.slice(0, 300)}` };
    return { raw: text };
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") return { error: "вызов не уложился в срок" };
    return { error: `сбой вызова: ${e}` };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Совместимый режим для `qwen3-asr-flash` — похож на чат, но не чат.
 *
 * Отличий от обычного вызова три, и каждое из них обязательное: в
 * `input_audio` едет ТОЛЬКО `data` (поле `format` этот путь не знает),
 * текстовой части рядом нет вовсе, а вместо системного сообщения —
 * `asr_options`. Поэтому вызов свой, а не через requestQwen.
 *
 * `enable_lid` — определение языка самим распознавателем: на этом и держится
 * проверка «сказал не на том языке». `enable_itn` выключен намеренно: он
 * превращает числа в цифры («two» → «2»), а нам нужно то, что произнесено,
 * иначе сравнение с нашим переводом развалится на ровном месте.
 */
async function compatAsr(
  model: string,
  audio: string,
  budgetMs: number,
): Promise<{ raw: string } | { error: string }> {
  const key = judgeKey();
  if (!key) return { error: "нет ключа модели" };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(5_000, budgetMs));
  try {
    const res = await fetch(`${judgeBaseUrl()}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      body: JSON.stringify({
        model,
        messages: [
          { role: "user", content: [{ type: "input_audio", input_audio: { data: audio } }] },
        ],
        asr_options: { enable_lid: true, enable_itn: false },
      }),
      signal: controller.signal,
    });
    const body = await res.text();
    if (!res.ok) return { error: `HTTP ${res.status}: ${body.slice(0, 400)}` };
    const text = chatText(body);
    if (text === null) return { error: `ответ без текста: ${body.slice(0, 300)}` };
    return { raw: text };
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") return { error: "вызов не уложился в срок" };
    return { error: `сбой вызова: ${e}` };
  } finally {
    clearTimeout(timer);
  }
}

/** Текст из частей ответа: они бывают строкой, бывают списком кусков. */
function partsText(content: unknown): string | null {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const parts = content
      .map((item: unknown) =>
        item && typeof item === "object" && typeof (item as { text?: unknown }).text === "string"
          ? (item as { text: string }).text
          : ""
      )
      .filter((t: string) => t.length > 0);
    if (parts.length > 0) return parts.join(" ");
  }
  return null;
}

/**
 * Достаёт расшифровку из ответа своей схемы. Форма ответа там вложенная.
 *
 * ПОРЯДОК ПОИСКА НЕ СЛУЧАЕН. Первым идёт `output.output.sentence.text` —
 * именно туда `qwen-audio-3.0-*` кладёт расшифровку, и документация особо
 * оговаривает, что это НЕ `output.choices`. Остальные ветки оставлены для
 * соседних моделей семейства: у них ответ приходит обычной чат-формой.
 *
 * Открыт наружу ради проверки: разборщик, который молча возвращает null,
 * выглядит точно так же, как «модель ничего не сказала», и отличить одно
 * от другого можно только тестом.
 */
export function nativeText(body: string): string | null {
  try {
    const parsed = JSON.parse(body);
    const sentence = parsed?.output?.output?.sentence;
    if (typeof sentence?.text === "string") return sentence.text;
    // Несколько фраз подряд — склеиваем, порядок провайдер держит сам.
    if (Array.isArray(sentence)) {
      const said = sentence
        .map((s: unknown) =>
          s && typeof s === "object" && typeof (s as { text?: unknown }).text === "string"
            ? (s as { text: string }).text
            : ""
        )
        .filter((t: string) => t.length > 0);
      if (said.length > 0) return said.join(" ");
    }
    const choice = partsText(parsed?.output?.choices?.[0]?.message?.content);
    if (choice !== null) return choice;
    // Некоторые ответы кладут текст прямо в output.text.
    if (typeof parsed?.output?.text === "string") return parsed.output.text;
    return null;
  } catch {
    return null;
  }
}

/**
 * Достаёт текст из обычного (не потокового) ответа совместимого режима.
 *
 * Открыт наружу по той же причине, что и nativeText: пустой разбор и
 * молчание модели снаружи неотличимы.
 */
export function chatText(body: string): string | null {
  try {
    const parsed = JSON.parse(body);
    return partsText(parsed?.choices?.[0]?.message?.content);
  } catch {
    return null;
  }
}

/** Аудио раунда в том виде, в каком его принимает мультимодальная модель. */
function audioPart(audio: Uint8Array, format: string): unknown {
  return {
    type: "input_audio",
    input_audio: {
      data: `data:audio/${format};base64,${base64(audio)}`,
      format,
    },
  };
}

/**
 * Убирает то, чем модели обрамляют расшифровку.
 *
 * Часть из них отвечает не голым текстом, а вежливо: кавычки вокруг, иногда
 * markdown-заборчик, иногда «Transcription:» впереди. Всё это попало бы в
 * ленту разбора как слова игрока и зачёркивалось бы красным.
 */
function cleanTranscript(raw: string): string {
  let text = raw.trim();
  const fence = text.match(/^```[a-z]*\n([\s\S]*?)\n?```$/i);
  if (fence) text = fence[1].trim();
  text = text.replace(/^(transcription|transcript|text)\s*[:：]\s*/i, "").trim();
  if (text.length > 1 && /^["'«].*["'»]$/s.test(text)) text = text.slice(1, -1).trim();
  return text;
}
