// Провайдер-агностичный LLM-адаптер (раздел 9.2 спеки). Единственная точка
// входа в LLM для всего проекта — base_url/api_key/model читаются из env,
// смена провайдера (DeepSeek -> Mistral/Groq/Qwen) это правка переменных
// окружения Edge Function, а не кода.

export interface GrammarError {
  offset: number;
  length: number;
  message: string;
  replacement: string;
  category: "grammar" | "spelling" | "style";
}

export interface EvaluateGrammarResult {
  /** Балл 1-10 напрямую из ответа модели (раздел 9.4, MVP-версия). */
  score: number;
  errors: GrammarError[];
  /** true, если модель так и не вернула валидный ответ и балл нейтральный. */
  degraded: boolean;
}

/**
 * Нейтральный балл при неустранимом сбое НАШЕЙ стороны (модель не ответила,
 * ASR не смог распознать) — игрока за свою поломку не штрафуем. Экспортирован,
 * потому что тем же баллом заканчивается сбой распознавания речи в
 * evaluate-recording (см. transcribeAudio.ts).
 */
export const NEUTRAL_SCORE = 7;

const BASE_SYSTEM_PROMPT =
  `Ты — строгий, но доброжелательный судья грамматики для приложения изучения языков.
Тебе дают транскрипт того, что сказал изучающий язык (уровень A1-B2), целевой язык и родной язык говорящего.
Твоя задача — оценить сказанное по 10-балльной шкале и найти ошибки грамматики, орфографии и стиля в транскрипте.
НЕ оценивай произношение — ты видишь только текст.
НЕ штрафуй за то, что укладывается в разговорную норму или является допустимым вариантом.

Верни СТРОГО JSON без markdown-разметки в формате:
{"score": number, "errors": [{"offset": number, "length": number, "message": string, "replacement": string, "category": "grammar"|"spelling"|"style"}]}

score — целое число от 1 до 10: 10 — безупречно и естественно, 7-9 — понятно с мелкими огрехами,
4-6 — заметные ошибки, но смысл ясен, 1-3 — почти непонятно или не на том языке.
offset/length — позиция символа в ПЕРЕДАННОМ транскрипте (0-indexed, по UTF-16 code units).
replacement — как должно быть правильно.
category — "grammar" или "spelling" для настоящих ошибок; "style" для необязательных стилистических советов.
Если ошибок нет — верни {"score": 10, "errors": []}.`;

/// Обычный режим (PvP, раздел 2.4): message — короткое, одна-две фразы,
/// понятное с первого взгляда прямо в ленте боя.
const BRIEF_MESSAGE_INSTRUCTION =
  `message — короткое объяснение ошибки (одно-два предложения) НА РОДНОМ ЯЗЫКЕ говорящего, понятное новичку.`;

/// Одиночная Игра (раздел 2.2): между двумя попытками игрок должен понять,
/// что именно исправить — здесь ИИ обязан объяснять подробнее, чем в PvP,
/// а не просто оценивать и указывать на ошибку одной строкой.
const DETAILED_MESSAGE_INSTRUCTION =
  `message — ПОДРОБНОЕ объяснение ошибки НА РОДНОМ ЯЗЫКЕ говорящего, 3-5 предложений:
назови грамматическое правило, которое нарушено, объясни своими словами, почему форма из транскрипта
неверна, и приведи короткий дополнительный пример правильного употребления этого правила (не просто
повтори replacement). Это учебный режим с двумя попытками подряд — объяснение должно быть настолько
понятным, чтобы неноситель языка A1-B2 смог исправить ошибку во второй попытке, не просто скопировав
исправление.`;

export type CefrLevel = "A1" | "A2" | "B1" | "B2" | "C1" | "C2";

/**
 * Уровень игрока — внутренняя механика, приравненная к его лиге (Медная
 * Лига -> A1 ... Лига Мастеров -> C2, см. supabase/migrations/0010 и
 * lib/core/leagues.dart). НИГДЕ в интерфейсе не показывается — это только
 * ограничитель сложности ТЕКСТА ОБЪЯСНЕНИЙ (message/replacement), чтобы
 * говорящий действительно мог его понять/перевести своими силами. Сам балл
 * (score) от уровня не зависит и считается по одной и той же шкале для всех
 * — см. явное напоминание в конце каждого блока ниже.
 */
const LEVEL_INSTRUCTIONS: Record<CefrLevel, string> = {
  A1: `Уровень говорящего — A1 (полный новичок, знает от силы 500-1000 слов).
Объясняй ошибку предельно простыми словами и очень короткими предложениями.
Не используй грамматические термины сложнее "глагол"/"существительное"/
"окончание"/"порядок слов". Опирайся только на глагол to be, Present Simple,
Past Simple, Future Simple, единственное/множественное число — не объясняй
через более сложные времена или конструкции, даже если ошибка на самом деле
сложнее: сведи объяснение к тому, что говорящий способен понять и перевести
уже сейчас.`,
  A2: `Уровень говорящего — A2. Он уже знает to be, Present/Past/Future Simple,
неправильные глаголы, be going to, WH-questions, предлоги in/on/at. Объясняй
просто и короткими фразами, этими терминами пользоваться можно, но не
опирайся на Present Perfect, Passive Voice, условные предложения, герундий/
инфинитив — для него это ещё не пройдено.`,
  B1: `Уровень говорящего — B1. Он знает порядок слов, модальные have to/must,
условные предложения 0/1/2, инфинитив и герундий, Present Continuous, Past
Continuous, Future Simple, Present Perfect. Объяснение может быть чуть
подробнее и свободно ссылаться на эти темы, но не на Passive Voice,
смешанные условные или инверсию — этого он ещё не проходил.`,
  B2: `Уровень говорящего — B2. Он знает Passive Voice, все формы будущего,
Present Perfect и Present Perfect Continuous, сравнительные/превосходные
степени, модальные глаголы, герундий/инфинитив, условные предложения,
фразовые глаголы. Объясняй развёрнуто, этой терминологией и примерами
пользоваться можно свободно.`,
  C1: `Уровень говорящего — C1. Он свободно ориентируется в повествовательных
временах, used to/would, стилистической инверсии, инверсии в условных
предложениях, каузативных конструкциях. Объяснение может быть подробным и
использовать точную грамматическую терминологию, не упрощай ради упрощения.`,
  C2: `Уровень говорящего — C2, практически как у носителя языка. Объясняй
так же тонко и подробно, как для продвинутого лингвиста или преподавателя:
можно свободно использовать любую грамматическую терминологию, идиомы и
стилистические нюансы.`,
};

const LEVEL_SCORE_REMINDER =
  `Уровень выше касается ТОЛЬКО того, какими словами и терминами ты объясняешь
ошибку (message/replacement) — сам балл (score) по-прежнему выставляй
объективно по единой шкале для всех уровней, не занижай и не завышай его
из-за уровня говорящего.`;

function buildSystemPrompt(detailed: boolean, level: CefrLevel): string {
  const levelBlock = `${LEVEL_INSTRUCTIONS[level]}\n${LEVEL_SCORE_REMINDER}`;
  return `${BASE_SYSTEM_PROMPT}\n${levelBlock}\n${detailed ? DETAILED_MESSAGE_INSTRUCTION : BRIEF_MESSAGE_INSTRUCTION}`;
}

function buildUserPrompt(transcript: string, targetLanguage: string, nativeLanguage: string): string {
  return [
    `Целевой язык (на котором говорил учащийся): ${targetLanguage}`,
    `Родной язык учащегося (на нём объясняй ошибки): ${nativeLanguage}`,
    `Транскрипт:`,
    transcript,
  ].join("\n");
}

interface ParsedResult {
  score: number;
  errors: GrammarError[];
}

/**
 * Раздел 9.3: ответ модели валидируется по схеме ПЕРЕД использованием.
 * Возвращает null, если форма ответа не подходит — вызывающий код решает,
 * повторять запрос или отдавать нейтральный результат.
 */
function validate(value: unknown): ParsedResult | null {
  if (typeof value !== "object" || value === null) return null;
  const v = value as Record<string, unknown>;

  if (typeof v.score !== "number" || !Number.isFinite(v.score)) return null;
  const score = Math.min(10, Math.max(1, Math.round(v.score)));

  if (!Array.isArray(v.errors)) return null;
  const errors: GrammarError[] = [];
  for (const e of v.errors) {
    if (typeof e !== "object" || e === null) return null;
    const err = e as Record<string, unknown>;
    if (
      typeof err.offset !== "number" ||
      typeof err.length !== "number" ||
      typeof err.message !== "string" ||
      typeof err.replacement !== "string" ||
      (err.category !== "grammar" && err.category !== "spelling" && err.category !== "style")
    ) {
      return null;
    }
    errors.push({
      offset: Math.max(0, Math.round(err.offset)),
      length: Math.max(0, Math.round(err.length)),
      message: err.message,
      replacement: err.replacement,
      category: err.category,
    });
  }

  return { score, errors };
}

async function callLlmOnce(
  transcript: string,
  targetLanguage: string,
  nativeLanguage: string,
  detailed: boolean,
  level: CefrLevel,
): Promise<unknown> {
  const baseUrl = Deno.env.get("LLM_BASE_URL") ?? "https://api.b.ai/v1";
  const apiKey = Deno.env.get("LLM_API_KEY");
  const model = Deno.env.get("LLM_MODEL") ?? "DeepSeek-V4-Flash";

  if (!apiKey) {
    throw new Error("LLM_API_KEY is not configured");
  }

  // Таймаут обязателен: без него зависший/медленный провайдер держит
  // запрос до убийства всей Edge Function платформой, а это происходит
  // ДО catch-блока — evaluation_jobs так и останется в 'processing'
  // навсегда, и клиент (ждущий 'done'/'failed') зависнет на экране
  // "Разбираю попытку" без единой ошибки в логах. С таймаутом fetch
  // сам бросает исключение, которое ловит retry-цикл evaluateGrammar.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 20_000);

  let res: Response;
  try {
    res = await fetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: buildSystemPrompt(detailed, level) },
          { role: "user", content: buildUserPrompt(transcript, targetLanguage, nativeLanguage) },
        ],
        // Явно нестриминговый ответ: нам нужен один цельный JSON-объект,
        // а не поток чанков (некоторые провайдеры включают стриминг по
        // умолчанию, если поле вообще не передано).
        stream: false,
        // Structured output там, где провайдер это поддерживает (раздел 9.3).
        response_format: { type: "json_object" },
        temperature: 0.2,
      }),
      signal: controller.signal,
    });
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") {
      throw new Error("LLM request timed out after 20s");
    }
    throw e;
  } finally {
    clearTimeout(timeout);
  }

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`LLM HTTP ${res.status}: ${body.slice(0, 500)}`);
  }

  const data = await res.json();
  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== "string") {
    throw new Error("LLM response missing message content");
  }
  return JSON.parse(content);
}

/**
 * evaluateGrammar(transcript, targetLanguage, nativeLanguage) -> { score, errors }
 *
 * Раздел 9.3: один повторный запрос при кривом JSON/ответе, затем —
 * нейтральный результат вместо падения/штрафа игроку. Приложение никогда
 * не должно падать из-за ответа модели.
 */
export async function evaluateGrammar(
  transcript: string,
  targetLanguage: string,
  nativeLanguage: string,
  /**
   * true — Одиночная Игра (раздел 2.2): подробный разбор ошибки между
   * попыткой №1 и №2. false — PvP (раздел 2.4): короткая пометка в ленте
   * боя. Балл (score) считается одинаково в обоих случаях — отличается
   * только глубина текста в message у найденных ошибок.
   */
  detailed = false,
  /**
   * Уровень говорящего (его лига, приравненная к CEFR — см.
   * supabase/migrations/0010). Ограничивает только сложность ТЕКСТА
   * объяснений, не саму строгость оценки — см. LEVEL_SCORE_REMINDER.
   */
  level: CefrLevel = "A1",
): Promise<EvaluateGrammarResult> {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const parsed = validate(await callLlmOnce(transcript, targetLanguage, nativeLanguage, detailed, level));
      if (parsed) {
        return { score: parsed.score, errors: parsed.errors, degraded: false };
      }
      console.error("evaluateGrammar: LLM returned invalid shape, attempt", attempt);
    } catch (e) {
      console.error("evaluateGrammar: attempt", attempt, "failed:", e);
    }
  }
  return { score: NEUTRAL_SCORE, errors: [], degraded: true };
}
