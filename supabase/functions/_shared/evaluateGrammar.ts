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
  errors: GrammarError[];
}

const SYSTEM_PROMPT = `Ты — строгий, но доброжелательный судья грамматики для приложения изучения языков.
Тебе дают транскрипт того, что сказал изучающий язык (уровень A1-B2), целевой язык и родной язык говорящего.
Твоя задача — найти ТОЛЬКО ошибки грамматики, орфографии и (отдельно) стилистические огрехи в транскрипте.
НЕ оценивай произношение — ты видишь только текст.
НЕ штрафуй и не отмечай как ошибку то, что укладывается в разговорную норму или является допустимым вариантом.

Верни СТРОГО JSON без markdown-разметки в формате:
{"errors": [{"offset": number, "length": number, "message": string, "replacement": string, "category": "grammar"|"spelling"|"style"}]}

offset/length — позиция символа в ПЕРЕДАННОМ транскрипте (0-indexed, по UTF-16 code units).
message — короткое объяснение ошибки НА РОДНОМ ЯЗЫКЕ говорящего, понятное новичку.
replacement — как должно быть правильно.
category — "grammar" или "spelling" для настоящих ошибок; "style" для необязательных стилистических советов ("носитель сказал бы иначе") — они не штрафуются, но могут быть показаны отдельно.
Если ошибок нет — верни {"errors": []}.`;

function buildUserPrompt(transcript: string, targetLanguage: string, nativeLanguage: string): string {
  return [
    `Целевой язык (на котором говорил учащийся): ${targetLanguage}`,
    `Родной язык учащегося (на нём объясняй ошибки): ${nativeLanguage}`,
    `Транскрипт:`,
    transcript,
  ].join("\n");
}

function isValidResult(value: unknown): value is EvaluateGrammarResult {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  if (!Array.isArray(v.errors)) return false;
  return v.errors.every((e) => {
    if (typeof e !== "object" || e === null) return false;
    const err = e as Record<string, unknown>;
    return (
      typeof err.offset === "number" &&
      typeof err.length === "number" &&
      typeof err.message === "string" &&
      typeof err.replacement === "string" &&
      (err.category === "grammar" || err.category === "spelling" || err.category === "style")
    );
  });
}

async function callLlmOnce(transcript: string, targetLanguage: string, nativeLanguage: string): Promise<unknown> {
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
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: buildUserPrompt(transcript, targetLanguage, nativeLanguage) },
      ],
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
 * evaluateGrammar(transcript, targetLanguage, nativeLanguage) -> { errors }
 *
 * Раздел 9.3: один повторный запрос при кривом JSON/ответе, затем —
 * нейтральный результат (без ошибок) вместо падения/штрафа игроку.
 */
export async function evaluateGrammar(
  transcript: string,
  targetLanguage: string,
  nativeLanguage: string,
): Promise<EvaluateGrammarResult> {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const parsed = await callLlmOnce(transcript, targetLanguage, nativeLanguage);
      if (isValidResult(parsed)) {
        return parsed;
      }
      console.error("evaluateGrammar: LLM returned invalid shape, attempt", attempt, parsed);
    } catch (e) {
      console.error("evaluateGrammar: attempt", attempt, "failed:", e);
    }
  }
  // Неустранимый сбой модели — не штрафуем игрока.
  return { errors: [] };
}
