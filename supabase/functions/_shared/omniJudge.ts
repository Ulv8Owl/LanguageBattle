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
  /**
   * Перевод, сделанный САМОЙ моделью. Он же — «Разбор:» на экране.
   *
   * Это не эталон из датасета: эталона модель не видела. Она переводила
   * то же задание, что и игрок, и сравнивала с собственным результатом.
   */
  correct: string;
  /**
   * Куски [correct], смысл которых игрок не передал вовсе.
   *
   * Цитаты из [correct] дословно — по ним приложение красит несказанное и
   * по ним же считается доля потерянного.
   */
  missing: string[];
  /** Ошибки, найденные моделью. Пустой список — сказано верно. */
  errors: OmniError[];
  /** Модель не ответила или ответила не тем. Балл тогда нейтральный. */
  degraded: boolean;
  failureReason?: string;
  debug: Record<string, unknown>;
}

/**
 * Балл за ответ считает ПРОГРАММА, а не модель.
 *
 * Числовая оценка от модели была самой шаткой частью ответа: на одной и
 * той же записи она гуляла на два-три балла и объяснить её игроку было
 * нечем. Арифметика по её же разбору повторяема и проговаривается одной
 * фразой — «половину не сказал и две ошибки».
 *
 * Формула: из десяти вычитаем долю несказанного (не сказал 60% — минус 6)
 * и по баллу за каждую отдельную ошибку. Ниже единицы не опускаемся:
 * единица и есть «ничего не получилось», отрицательных баллов в игре нет.
 */
export function scoreFor(correct: string, missing: string[], errorCount: number): number {
  const total = correct.replace(/\s+/g, " ").trim().length;
  // Перевода нет — считать долю не от чего. Тогда единственное, что у нас
  // есть, это ошибки: пусть отвечают только они.
  const share = total === 0 ? 0 : Math.min(1, missingLength(correct, missing) / total);
  const score = 10 - Math.round(10 * share) - errorCount;
  return Math.max(1, Math.min(10, score));
}

/**
 * Сколько символов [correct] покрыто пропусками.
 *
 * Считаем ПО ВХОЖДЕНИЯМ в текст перевода, а не суммой длин цитат. Модель
 * может процитировать один и тот же кусок дважды или прислать фрагмент,
 * которого в переводе нет вовсе, — и в обоих случаях сумма длин завысила
 * бы потерю, а игрок недосчитался бы баллов за нашу арифметику.
 */
function missingLength(correct: string, missing: string[]): number {
  const haystack = correct.toLowerCase();
  // Отмечаем покрытые символы, поэтому повторная цитата ничего не добавит.
  const covered = new Array<boolean>(correct.length).fill(false);
  for (const raw of missing) {
    const needle = raw.replace(/\s+/g, " ").trim().toLowerCase();
    if (needle.length === 0) continue;
    let from = 0;
    for (;;) {
      const at = haystack.indexOf(needle, from);
      if (at < 0) break;
      for (let i = at; i < at + needle.length && i < covered.length; i++) covered[i] = true;
      from = at + needle.length;
    }
  }
  return covered.filter(Boolean).length;
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

/**
 * Название языка НА НЁМ САМОМ.
 *
 * Нужно рядом с английским названием, и это не украшение. Инструкция
 * «explain in Russian» модель однажды прочитала как пожелание и ответила
 * по-испански — игрок с русским в паре получил разбор на языке, которого
 * не выбирал. Самоназвание работает как второй, независимый указатель: его
 * трудно перепутать, потому что оно написано той же письменностью, что и
 * требуемый ответ.
 */
const LANGUAGE_ENDONYMS: Record<string, string> = {
  en: "English",
  ru: "русский",
  es: "español",
};

function languageName(code: string): string {
  return LANGUAGE_NAMES[code.toLowerCase()] ?? code;
}

function languageEndonym(code: string): string {
  return LANGUAGE_ENDONYMS[code.toLowerCase()] ?? code;
}

/**
 * Инструкция модели.
 *
 * Написана по-английски намеренно: язык инструкции не должен подсказывать
 * модели, на каком языке ждут ОТВЕТ, — иначе объяснения сползают на язык
 * промпта. Нужный язык объяснений называется отдельно, дважды и с
 * самоназванием.
 *
 * ЧТО МОДЕЛЬ ДЕЛАЕТ ПО ПОРЯДКУ. Сначала переводит задание сама — у неё на
 * руках ровно то же, что у игрока, и ничего больше. Потом слушает запись и
 * сравнивает со СВОИМ переводом. Такой порядок важен: модель, которой
 * сразу дали слушать «ошибки», начинает их искать и находит на ровном
 * месте; модель, у которой уже есть собственный перевод, сравнивает два
 * текста и молчит там, где сравнивать нечего.
 *
 * БАЛЛ МОДЕЛЬ НЕ СТАВИТ. Его считает программа: доля несказанного плюс по
 * баллу за ошибку. Числовая оценка от модели была самой шаткой частью
 * ответа — на одной и той же записи она гуляла на два-три балла, — а
 * арифметика по её же разбору повторяема и объяснима игроку.
 */
function systemPrompt(nativeLanguage: string, targetLanguage: string, level: string): string {
  const native = languageName(nativeLanguage);
  const nativeSelf = languageEndonym(nativeLanguage);
  const target = languageName(targetLanguage);
  return [
    `You are a ${target} teacher. A ${native}-speaking learner at CEFR level ${level} was given a sentence`,
    `in ${native} and asked to say it aloud in ${target}. You get that sentence and the recording.`,
    "",
    "Work in this order:",
    `1. Translate the ${native} sentence into ${target} yourself. This is your reference — you have no other.`,
    "2. Listen to the recording and compare what you hear with your own translation.",
    "",
    "A different wording is NOT an error: a sentence can be translated in several correct ways, and you must",
    "accept any wording that conveys the same meaning correctly. Mark an error only when something is genuinely",
    "wrong — wrong meaning, wrong grammar, an invented word. Never mark stylistic preference.",
    "Group errors by MEANING: everything that goes wrong for one reason is a single error.",
    "",
    "Also list the parts of your translation whose meaning the learner did not convey at all — skipped or lost.",
    "Quote them verbatim from your own translation so they can be found in it character for character.",
    "",
    `LANGUAGE OF EXPLANATIONS: every "why" field must be written in ${native} (${nativeSelf}) and in no other`,
    `language. This is not a preference — the learner reads only ${nativeSelf}. Everything else (the translation,`,
    `the transcription, the quoted fragments, the corrections) stays in ${target}.`,
    `Explain at ${level} level: short and concrete, no grammar jargon the learner would not know.`,
    "",
    "Reply with a single JSON object and nothing else — no markdown, no commentary:",
    '{"correct": string, "missing": [string], "errors": [{"said": string, "fix": string, "why": string}]}',
    `"correct" — your translation. "missing" — fragments of "correct" the learner did not convey.`,
    `"said" — what the learner actually said at that point, quoted from the recording verbatim,`,
    `mistakes included; do not correct it there. "fix" — how it should sound in ${target}.`,
    `"why" — the explanation in ${nativeSelf}. Empty arrays when there is nothing to report.`,
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
    // Ключи короткие (said/fix/why): каждый повторяется в ответе столько
    // раз, сколько нашлось ошибок, и на длинном разборе это заметные
    // токены за нулевую пользу.
    const text = typeof row.said === "string" ? row.said.trim() : "";
    const message = typeof row.why === "string" ? row.why.trim() : "";
    // Ошибка без фрагмента показывается не к чему: плашка в разборе — это
    // и есть фрагмент. Ошибка без объяснения — пустая плашка, за которой
    // ничего нет; такую лучше не показывать вовсе, чем обещать разбор.
    if (text.length === 0 || message.length === 0) continue;
    out.push({
      text,
      message,
      correction: typeof row.fix === "string" ? row.fix.trim() : "",
    });
  }
  return out;
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
    correct: "",
    missing: [],
    errors: [],
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

  const system = systemPrompt(req.nativeLanguage, req.targetLanguage, req.level);

  const userParts: unknown[] = [
    {
      type: "input_audio",
      input_audio: {
        data: `data:audio/${req.audioFormat};base64,${base64(req.audio)}`,
        format: req.audioFormat,
      },
    },
  ];
  userParts.push({
    type: "text",
    text: `The learner was asked to say this in ${languageName(req.targetLanguage)}:\n${req.prompt}`,
  });

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

  const debug: Record<string, unknown> = {
    ...omniConfigDebug(),
    status: "ok",
    ms: Date.now() - started,
    audio_bytes: req.audio.byteLength,
    audio_format: req.audioFormat,
  };

  const correct = typeof parsed.correct === "string" ? parsed.correct.trim() : "";
  if (correct.length === 0) {
    // Без собственного перевода модели не с чем сравнивать, и «Разбор:»
    // показать нечем. Это сбой ответа, а не пустой результат.
    return fail(`в ответе нет перевода: ${raw.slice(0, 300)}`);
  }

  const missing = Array.isArray(parsed.missing)
    ? parsed.missing
      .filter((m): m is string => typeof m === "string")
      .map((m) => m.trim())
      .filter((m) => m.length > 0)
    : [];
  const errors = asErrors(parsed.errors);

  debug.correct = correct;
  debug.missing = missing;
  debug.errors = errors.length;
  // Сколько ошибок модель назвала и сколько мы оставили — расхождение
  // означает, что часть пришла без фрагмента или без объяснения, и это
  // видно только здесь.
  debug.errors_raw = Array.isArray(parsed.errors) ? parsed.errors.length : 0;
  debug.score_formula = `10 - доля несказанного - ${errors.length}`;

  return { correct, missing, errors, degraded: false, debug };
}
