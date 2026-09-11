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
 * ═══ ПОЧЕМУ ЗДЕСЬ ЛЕСЕНКА ИЗ ТРЁХ ПОПЫТОК ═══
 *
 * Потому что провайдер обслуживает эти модели НЕ ТАК, как мультимодальную, и
 * как именно — по документации было не угадать. Три круга проверок на живых
 * записях дали вот что:
 *
 *   * `qwen-audio-3.0-asr-flash` через OpenAI-совместимый путь отвечает
 *     HTTP 400 «format is empty» — и вложенным аудио, и ссылкой, и с
 *     текстовой частью рядом, и без неё. Формат при этом передаётся и он
 *     заведомо непустой: приложение пишет только WAV;
 *   * `fun-asr-mtl` отвечает честнее: HTTP 404 «Unsupported model for
 *     OpenAI compatibility mode» — то есть через этот путь его нет вовсе.
 *
 * Второй ответ и объясняет первый: у DashScope есть СВОЙ, не
 * OpenAI-совместимый endpoint для мультимодальных генераций, и модели
 * распознавания живут там. Совместимый путь либо не знает их, либо знает
 * наполовину.
 *
 * Поэтому вместо четвёртого круга угадываний — три формы вызова подряд, до
 * первой, которая ответит текстом. Отказ приходит мгновенно и не стоит
 * ничего: за неудавшийся запрос провайдер денег не берёт, а получасовой
 * круг «собери — поставь — попробуй» стоит дорого.
 *
 * КАКАЯ ФОРМА СРАБОТАЛА, ВИДНО В ОТЛАДКЕ ЗАПИСИ (`asr.shape`), и все
 * неудавшиеся попытки лежат там же со своими ответами. Как только станет
 * известно, какая именно нужна, лесенку надо свернуть до неё одной —
 * лишние попытки это лишняя задержка на каждом раунде.
 */

import { base64, judgeBaseUrl, judgeKey, requestQwen } from "./review.ts";

/**
 * Модели распознавания, между которыми можно переключаться из настроек.
 *
 * ПОРЯДОК — ТОТ, В КОТОРОМ ИХ НАЗВАЛ ВЛАДЕЛЕЦ ПРОЕКТА, и первая работает
 * моделью по умолчанию. Список продублирован на клиенте (judge_models.dart)
 * намеренно: значение из профиля игрока — ввод снаружи, и проверять его
 * надо там, где им пользуются, иначе опечатка уедет в тело запроса.
 */
export const ASR_MODELS = [
  "qwen-audio-3.0-asr-flash",
  "qwen-audio-3.0-asr-flash-filetrans",
  "fun-asr-mtl",
  "qwen3-asr-flash",
  "qwen3-asr-flash-filetrans",
  "fun-asr-flash-2026-06-15",
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
  /** Подписанная ссылка на запись. Нужна двум формам вызова из трёх. */
  audioUrl?: string | null;
  audio: Uint8Array;
  audioFormat: string;
  model?: string | null;
  budgetMs: number;
}): Promise<AsrResult> {
  const started = Date.now();
  const model = asrModel(req.model);
  const url = (req.audioUrl ?? "").trim();
  const attempts: Attempt[] = [];
  const left = () => req.budgetMs - (Date.now() - started);

  const debug = (extra: Record<string, unknown> = {}) => ({
    provider: "asr",
    model,
    model_requested: (req.model ?? "").trim().length > 0 ? req.model : null,
    base_url: judgeBaseUrl(),
    audio_bytes: req.audio.byteLength,
    audio_format: req.audioFormat,
    has_url: url.length > 0,
    attempts,
    ms: Date.now() - started,
    ...extra,
  });

  if (req.audio.byteLength === 0 && url.length === 0) {
    return { text: "", error: "запись пуста", debug: debug({ status: "failed" }) };
  }

  // Формы по порядку. Первая — та, что заведомо работает с мультимодальной
  // моделью на соседней ветке; дальше — своя схема провайдера.
  const shapes: { name: string; run: () => Promise<{ raw: string } | { error: string }> }[] = [];

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
  if (url.length > 0) {
    shapes.push({
      name: "compat-url",
      run: () =>
        requestQwen(
          "You are a speech transcriber. Write down exactly what is said and nothing else.",
          [
            // Формат передаём и здесь: ссылка на файл в хранилище несёт
            // токен в запросе, и расширение из неё вычитывается неверно.
            { type: "input_audio", input_audio: { data: url, format: req.audioFormat } },
            { type: "text", text: "Transcribe this recording." },
          ],
          left(),
          model,
          { audio: true, temperature: 0 },
        ),
    });
    shapes.push({ name: "native-url", run: () => nativeTranscribe(model, url, left()) });
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
 * Живёт на том же хосте, но по другому пути, и тело у неё другое: аудио
 * ссылкой внутри `input.messages`, ответ — в `output.choices`. Именно про
 * этот путь провайдер и говорит, отказывая моделям в совместимом режиме.
 */
async function nativeTranscribe(
  model: string,
  audioUrl: string,
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
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      body: JSON.stringify({
        model,
        input: { messages: [{ role: "user", content: [{ audio: audioUrl }] }] },
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
 * Достаёт расшифровку из ответа своей схемы. Форма ответа там вложенная.
 *
 * Открыт наружу ради проверки: разборщик, который молча возвращает null,
 * выглядит точно так же, как «модель ничего не сказала», и отличить одно
 * от другого можно только тестом.
 */
export function nativeText(body: string): string | null {
  try {
    const parsed = JSON.parse(body);
    const content = parsed?.output?.choices?.[0]?.message?.content;
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
    // Некоторые ответы кладут текст прямо в output.text.
    if (typeof parsed?.output?.text === "string") return parsed.output.text;
    return null;
  } catch {
    return null;
  }
}

/** Аудио раунда в том виде, в каком его принимает провайдер. */
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
