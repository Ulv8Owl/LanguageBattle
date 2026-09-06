/**
 * Одна мультимодальная модель вместо связки «распознавание + судья».
 *
 * ЗАЧЕМ. Прежний путь был из двух шагов, и каждый терял своё. Распознавание
 * превращало речь в текст — и вместе с ним терялось всё, что слышно только
 * в звуке: произношение, ударение, оборванное слово. Судья дальше работал
 * с текстом и сверял его с ЭТАЛОНОМ — единственным «правильным» переводом.
 * У фразы почти всегда несколько верных переводов, и сверка с одним из них
 * наказывала за правильный ответ, сказанный иначе.
 *
 * Модель здесь слушает запись напрямую и оценивает перевод сама — как
 * преподаватель, у которого нет перед глазами единственно верного варианта.
 * Поэтому ЭТАЛОН СЮДА НЕ ПЕРЕДАЁТСЯ ВООБЩЕ. Это не экономия токенов и не
 * забывчивость: увидев эталон, модель немедленно начинает сверять с ним, и
 * мы возвращаемся ровно к той проблеме, ради которой всё затевалось.
 * Единственное, что она получает кроме звука, — задание на родном языке
 * игрока, то самое, которое он видел на экране.
 *
 * ГРАНИЦЫ ОШИБОК модель проводит сама, по смыслу: «вот этот кусок сказан
 * не так». Не по элементам эталона — про элементы она не знает и знать не
 * должна. Элементы остались только у подсказок, где перевод ручной.
 *
 * ПРОТОКОЛ. Сервис OpenAI-совместимый (DashScope), поэтому запрос
 * выглядит как /chat/completions с аудио в content. Две особенности,
 * которых нет у обычного чата:
 *   * stream обязателен — без него сервис отвечает ошибкой;
 *   * modalities говорит, что нам нужен только текст. Модель умеет и
 *     отвечать голосом, но озвучка у нас своя (Cloud TTS), и просить ещё и
 *     аудио значило бы платить за то, что тут же выбросим.
 */

export interface OmniError {
  /** Фрагмент того, что игрок сказал, — к нему привязано объяснение. */
  text: string;
  /** Объяснение на родном языке игрока. */
  message: string;
  /** Как надо было сказать. Пусто — модель не предложила. */
  correction: string;
}

export interface OmniResult {
  /** Что модель услышала, на изучаемом языке. */
  heard: string;
  /** Балл 1..10. */
  score: number;
  /** Ошибки, найденные моделью. Пустой список — сказано верно. */
  errors: OmniError[];
  /** Сводка одной фразой для ленты боя. */
  summary: string;
  /** Модель не ответила или ответила не тем. Балл тогда нейтральный. */
  degraded: boolean;
  failureReason?: string;
  debug: Record<string, unknown>;
}

const DEFAULT_BASE = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1";
const DEFAULT_MODEL = "qwen3-omni-flash";

export function omniEnabled(): boolean {
  return (Deno.env.get("OMNI_ENABLED") ?? "0") === "1";
}

export function omniKey(): string | null {
  const key = Deno.env.get("OMNI_API_KEY");
  return key && key.length > 0 ? key : null;
}

export function omniModel(): string {
  return Deno.env.get("OMNI_MODEL") ?? DEFAULT_MODEL;
}

export function omniBaseUrl(): string {
  const own = Deno.env.get("OMNI_BASE_URL");
  return own && own.length > 0 ? own : DEFAULT_BASE;
}

export function omniConfigDebug(): Record<string, unknown> {
  return {
    provider: "omni",
    model: omniModel(),
    base_url: omniBaseUrl(),
    key_set: omniKey() !== null,
  };
}

const TIMEOUT_MS = Number(Deno.env.get("OMNI_TIMEOUT_MS") ?? 90_000);

/** Меньше этого запускать вызов бессмысленно — он не успеет вернуться. */
const MIN_SLICE_MS = 8_000;

const LANGUAGE_NAMES: Record<string, string> = {
  en: "English",
  ru: "Russian",
  es: "Spanish",
};

function languageName(code: string): string {
  return LANGUAGE_NAMES[code.toLowerCase()] ?? code;
}

/**
 * Инструкция модели.
 *
 * Написана по-английски намеренно: язык инструкции не должен подсказывать
 * модели, на каком языке ждут ОТВЕТ, — иначе объяснения начинают сползать
 * на язык промпта. Нужный язык объяснений называется отдельно и явно.
 */
function systemPrompt(nativeLanguage: string, targetLanguage: string, level: string): string {
  const native = languageName(nativeLanguage);
  const target = languageName(targetLanguage);
  return [
    `You are a ${target} teacher assessing a spoken translation by a ${native}-speaking learner at CEFR level ${level}.`,
    `You will hear an audio recording. The learner was asked to say a given ${native} sentence in ${target}.`,
    "",
    "Judge the translation on its own merits. There is NO reference answer, and you must not invent one:",
    `a sentence can be translated into ${target} in several correct ways, and a different wording is not an error.`,
    "Mark something as an error only when it is genuinely wrong: wrong meaning, wrong grammar, a missing or",
    "invented part of the message, or a word that does not exist. Do not mark stylistic preferences.",
    "",
    "Group errors by MEANING, not by word: everything that goes wrong for one reason is a single error.",
    `For each error quote the exact fragment of what the learner SAID (in ${target}, verbatim from the audio),`,
    `explain in ${native} why it is wrong and what the rule is, and give the corrected form of that fragment.`,
    `Write explanations for a ${level} learner: concrete and short, no grammar jargon they would not know.`,
    "",
    "Scoring, 1 to 10: 10 — the message is conveyed accurately and naturally; 7-9 — understandable with minor",
    "slips; 4-6 — understandable but with errors that change or blur the meaning; 2-3 — barely conveys the",
    "message; 1 — wrong language, silence, or unrelated speech.",
    "",
    "Reply with a single JSON object and nothing else — no markdown, no commentary:",
    '{"heard": string, "score": integer 1-10, "summary": string, "errors": [{"text": string, "message": string, "correction": string}]}',
    `"heard" is what you heard, transcribed in ${target} exactly as spoken, including mistakes — do not fix them.`,
    `"summary" is one short sentence in ${native}. If there are no errors, "errors" is an empty array.`,
  ].join("\n");
}

/** Только услышать — без оценки. Нужен, когда балл считается по элементам. */
function transcribeOnlyPrompt(targetLanguage: string): string {
  const target = languageName(targetLanguage);
  return [
    `Transcribe the ${target} speech in this recording exactly as spoken, including any mistakes.`,
    "Do not correct, complete or rephrase anything you hear.",
    'Reply with a single JSON object and nothing else: {"heard": string}',
  ].join("\n");
}

function base64(bytes: Uint8Array): string {
  // По кускам: у аудио раунда десятки-сотни килобайт, и одним
  // String.fromCharCode(...bytes) на таком размере рвётся стек аргументов.
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/**
 * Собирает текст из потокового ответа.
 *
 * stream обязателен для этой модели, поэтому разбор SSE — не оптимизация, а
 * единственный доступный способ прочитать ответ.
 */
async function readStream(res: Response): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) throw new Error("omni: пустой поток ответа");
  const decoder = new TextDecoder();
  let buffer = "";
  let text = "";

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    // События разделены пустой строкой; последний кусок буфера может быть
    // оборван на середине, поэтому его оставляем до следующей порции.
    const parts = buffer.split("\n");
    buffer = parts.pop() ?? "";
    for (const line of parts) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("data:")) continue;
      const payload = trimmed.slice(5).trim();
      if (payload === "[DONE]") continue;
      try {
        const chunk = JSON.parse(payload);
        const delta = chunk?.choices?.[0]?.delta;
        if (typeof delta?.content === "string") text += delta.content;
      } catch {
        // Обрывок, который не разобрался как JSON, — не повод ронять
        // весь ответ: следующие события всё равно принесут содержимое.
      }
    }
  }
  return text;
}

/** Достаёт JSON-объект из ответа, даже если модель обернула его в текст. */
function parseJson(raw: string): Record<string, unknown> | null {
  const trimmed = raw.trim();
  const candidates = [trimmed];
  // Модель может обернуть ответ в ```json ... ``` вопреки инструкции.
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced) candidates.push(fenced[1]);
  const braced = trimmed.match(/\{[\s\S]*\}/);
  if (braced) candidates.push(braced[0]);

  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
    } catch {
      // Пробуем следующий вариант.
    }
  }
  return null;
}

function asErrors(raw: unknown): OmniError[] {
  if (!Array.isArray(raw)) return [];
  const out: OmniError[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const row = item as Record<string, unknown>;
    const text = typeof row.text === "string" ? row.text.trim() : "";
    const message = typeof row.message === "string" ? row.message.trim() : "";
    // Ошибка без фрагмента показывается не к чему: плашка в разборе — это
    // и есть фрагмент. Ошибка без объяснения — пустая плашка, за которой
    // ничего нет; такую лучше не показывать вовсе, чем обещать разбор.
    if (text.length === 0 || message.length === 0) continue;
    out.push({
      text,
      message,
      correction: typeof row.correction === "string" ? row.correction.trim() : "",
    });
  }
  return out;
}

function clampScore(raw: unknown): number | null {
  const value = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(value)) return null;
  return Math.max(1, Math.min(10, Math.round(value)));
}

export interface OmniRequest {
  audio: Uint8Array;
  /** Контейнер записи: wav, mp3, m4a — как есть у нас в хранилище. */
  audioFormat: string;
  nativeLanguage: string;
  targetLanguage: string;
  /** Задание на РОДНОМ языке — то, что видел игрок. */
  prompt: string;
  level: string;
  /**
   * Нужна ли оценка. false — просим только услышанное: балл в этом случае
   * считается по элементам, и платить за разбор, который никто не покажет,
   * незачем.
   */
  wantJudgement: boolean;
  /** Остаток бюджета задачи. Пережить его вызов не имеет права. */
  budgetMs: number;
}

/**
 * Один вызов модели: звук на вход, разбор на выход.
 *
 * НИКОГДА НЕ БРОСАЕТ. Сбой провайдера — это degraded: true, а не падение
 * воркера. Иначе задача осталась бы висеть в 'processing', а игрок ждал бы
 * результат, которого не будет.
 */
export async function omniEvaluate(req: OmniRequest): Promise<OmniResult> {
  const started = Date.now();
  const fail = (reason: string, extra: Record<string, unknown> = {}): OmniResult => ({
    heard: "",
    score: 0,
    errors: [],
    summary: "",
    degraded: true,
    failureReason: reason,
    debug: { ...omniConfigDebug(), status: "failed", reason, ms: Date.now() - started, ...extra },
  });

  const key = omniKey();
  if (!key) {
    return fail("нет ключа модели: npx supabase secrets set OMNI_API_KEY=<ключ>");
  }
  if (req.audio.byteLength === 0) return fail("запись пуста");

  const timeoutMs = Math.min(TIMEOUT_MS, req.budgetMs);
  if (timeoutMs < MIN_SLICE_MS) {
    return fail(`на вызов осталось ${Math.round(req.budgetMs / 1000)}с — меньше минимума`);
  }

  const system = req.wantJudgement
    ? systemPrompt(req.nativeLanguage, req.targetLanguage, req.level)
    : transcribeOnlyPrompt(req.targetLanguage);

  // Задание уходит ОТДЕЛЬНОЙ строкой и только при оценке. В режиме
  // «только услышать» его нет намеренно: зная ожидаемый смысл, модель
  // склонна дописывать за игрока то, чего он не сказал.
  const userParts: unknown[] = [
    {
      type: "input_audio",
      input_audio: {
        data: `data:audio/${req.audioFormat};base64,${base64(req.audio)}`,
        format: req.audioFormat,
      },
    },
  ];
  if (req.wantJudgement) {
    userParts.push({
      type: "text",
      text: `The learner was asked to say this in ${languageName(req.targetLanguage)}:\n${req.prompt}`,
    });
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let raw = "";
  try {
    const res = await fetch(`${omniBaseUrl()}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        model: omniModel(),
        messages: [
          { role: "system", content: system },
          { role: "user", content: userParts },
        ],
        // Только текст: озвучка у нас своя, и просить у модели ещё и аудио
        // значило бы платить за то, что тут же выбросим.
        modalities: ["text"],
        // Обязателен для этой модели — без него сервис отвечает ошибкой.
        stream: true,
        stream_options: { include_usage: true },
        temperature: 0.2,
      }),
      signal: controller.signal,
    });

    if (!res.ok) {
      const body = await res.text().catch(() => "");
      return fail(`HTTP ${res.status}: ${body.slice(0, 400)}`);
    }
    raw = await readStream(res);
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") {
      return fail(`вызов не уложился в ${Math.round(timeoutMs / 1000)}с`);
    }
    return fail(`сбой вызова: ${e}`);
  } finally {
    clearTimeout(timer);
  }

  if (raw.trim().length === 0) return fail("модель вернула пустой ответ");

  const parsed = parseJson(raw);
  if (!parsed) return fail(`ответ не разобран как JSON: ${raw.slice(0, 300)}`);

  const heard = typeof parsed.heard === "string" ? parsed.heard.trim() : "";
  const debug: Record<string, unknown> = {
    ...omniConfigDebug(),
    status: "ok",
    mode: req.wantJudgement ? "оценка и разбор" : "только распознавание",
    ms: Date.now() - started,
    audio_bytes: req.audio.byteLength,
    audio_format: req.audioFormat,
    heard,
  };

  if (!req.wantJudgement) {
    // Балл не запрашивали — 0 здесь значит «не оценивали», и вызывающий
    // обязан посчитать его сам. Пустой транскрипт при этом не ошибка:
    // игрок мог промолчать, и это отдельное состояние, а не сбой.
    return { heard, score: 0, errors: [], summary: "", degraded: false, debug };
  }

  const score = clampScore(parsed.score);
  if (score === null) {
    return fail(`в ответе нет балла: ${raw.slice(0, 300)}`, { heard });
  }

  const errors = asErrors(parsed.errors);
  debug.score = score;
  debug.errors = errors.length;
  // Сколько ошибок модель назвала и сколько мы оставили — расхождение
  // означает, что часть пришла без фрагмента или без объяснения, и это
  // видно только здесь.
  debug.errors_raw = Array.isArray(parsed.errors) ? parsed.errors.length : 0;

  return {
    heard,
    score,
    errors,
    summary: typeof parsed.summary === "string" ? parsed.summary.trim() : "",
    degraded: false,
    debug,
  };
}
