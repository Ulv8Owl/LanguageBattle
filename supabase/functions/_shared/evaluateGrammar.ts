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

/** Нейтральный балл при неустранимом сбое модели — игрока не штрафуем. */
const NEUTRAL_SCORE = 7;

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

function buildSystemPrompt(detailed: boolean): string {
  return `${BASE_SYSTEM_PROMPT}\n${detailed ? DETAILED_MESSAGE_INSTRUCTION : BRIEF_MESSAGE_INSTRUCTION}`;
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
): Promise<unknown> {
  const baseUrl = Deno.env.get("LLM_BASE_URL") ?? "https://api.deepseek.com/v1";
  const apiKey = Deno.env.get("LLM_API_KEY");
  const model = Deno.env.get("LLM_MODEL") ?? "deepseek-chat";

  if (!apiKey) {
    throw new Error("LLM_API_KEY is not configured");
  }

  const res = await fetch(`${baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      messages: [
        { role: "system", content: buildSystemPrompt(detailed) },
        { role: "user", content: buildUserPrompt(transcript, targetLanguage, nativeLanguage) },
      ],
      // Structured output там, где провайдер это поддерживает (раздел 9.3).
      response_format: { type: "json_object" },
      temperature: 0.2,
    }),
  });

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
): Promise<EvaluateGrammarResult> {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const parsed = validate(await callLlmOnce(transcript, targetLanguage, nativeLanguage, detailed));
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
