/**
 * Один вызов модели — на любом из поддерживаемых провайдеров.
 *
 * ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. Модель зовут два места: судья (evaluateGrammar) и
 * разбор ошибок (explainElements). Раньше у каждого была своя копия
 * запроса — с таймаутом, откатом на повтор, разбором ответа и чтением
 * переменных окружения. Смена провайдера означала бы две одинаковые правки
 * в двух файлах, и разойтись они успели бы на первой же.
 *
 * ПРОВАЙДЕРЫ:
 *
 *   gemini (по умолчанию) — Google Gemini API, generativelanguage.googleapis.com.
 *   openai               — любой сервис с OpenAI-совместимым /chat/completions.
 *
 * Почему у Gemini выбран generateContent, а не Interactions API. Новый
 * Interactions API у Google действительно есть, и в документации он назван
 * интерфейсом по умолчанию. Но здесь нужен не текст, а СТРОГИЙ JSON
 * заданной формы — и контракт structured output (responseMimeType) я
 * достоверно знаю только для generateContent, который тот же документ
 * называет поддерживаемым. Гадать про формат ответа нового интерфейса,
 * когда от него зависит балл за раунд, — плохой размен. Переключить будет
 * недорого: точка входа одна, эта.
 */

/** Что просим у модели. */
export interface ChatRequest {
  /** Системная инструкция: правила ответа, формат, роль. */
  system: string;
  /** Собственно запрос — данные раунда. */
  user: string;
  /**
   * Просить строгий JSON. Первый заход всегда с true; повтор с false —
   * откат для провайдеров, которые такого поля не знают и отвечают на него
   * 400. Без отката судья у такого провайдера молча не работал бы вовсе.
   */
  json: boolean;
  temperature: number;
  /** Сколько отпущено на ЭТОТ запрос — уже с учётом бюджета всей задачи. */
  timeoutMs: number;
  /** 0 или undefined — не ограничивать длину ответа. */
  maxTokens?: number;
}

const DEFAULT_OPENAI_BASE = "https://api.b.ai/v1";
const DEFAULT_GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta";

export function llmProvider(): string {
  return (Deno.env.get("LLM_PROVIDER") ?? "gemini").toLowerCase();
}

/** Имя модели. Пусто — ошибка, и намеренно: см. комментарий в llmChat. */
export function llmModel(): string | null {
  const model = Deno.env.get("LLM_MODEL");
  return model && model.length > 0 ? model : null;
}

export function llmBaseUrl(): string {
  const own = Deno.env.get("LLM_BASE_URL");
  if (own && own.length > 0) return own;
  return llmProvider() === "gemini" ? DEFAULT_GEMINI_BASE : DEFAULT_OPENAI_BASE;
}

/** Что показать в отладочной панели, не раскрывая ключ. */
export function llmConfigDebug(): Record<string, unknown> {
  return {
    provider: llmProvider(),
    model: llmModel() ?? "(не задана)",
    base_url: llmBaseUrl(),
  };
}

/**
 * Отправляет один запрос и возвращает СЫРОЙ текст ответа модели.
 *
 * Разбор JSON, повторы и логирование — выше по стеку: здесь только
 * транспорт, чтобы у обоих вызывающих он был буквально один и тот же.
 *
 * Бросает на любой неудаче — это нормально: обе вызывающие стороны ловят
 * исключение, считают попытку неудачной и решают, повторять ли.
 */
export async function llmChat(apiKey: string, req: ChatRequest): Promise<string> {
  // Значения по умолчанию у имени модели СОЗНАТЕЛЬНО нет. Однажды здесь
  // стояло имя модели, которой у провайдера не существует, и каждый вызов
  // молча падал с model_not_found. Пусть лучше отсутствие настройки будет
  // явной ошибкой, чем «работающим» значением, которое не работает.
  const model = llmModel();
  if (!model) {
    throw new Error(
      "LLM_MODEL is not configured — задайте имя модели из списка провайдера: " +
        "npx supabase secrets set LLM_MODEL=<имя>",
    );
  }

  // Таймаут обязателен: без него зависший провайдер держит запрос до
  // убийства всей Edge Function платформой, а это происходит ДО
  // catch-блока — задача так и осталась бы в 'processing' навсегда.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), req.timeoutMs);

  try {
    return llmProvider() === "gemini"
      ? await callGemini(apiKey, model, req, controller.signal)
      : await callOpenAiCompatible(apiKey, model, req, controller.signal);
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") {
      throw new Error(`LLM request timed out after ${Math.round(req.timeoutMs / 1000)}s`);
    }
    throw e;
  } finally {
    clearTimeout(timeout);
  }
}

async function callGemini(
  apiKey: string,
  model: string,
  req: ChatRequest,
  signal: AbortSignal,
): Promise<string> {
  const url = `${llmBaseUrl()}/models/${encodeURIComponent(model)}:generateContent`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      // Ключ заголовком, а не в query: так он не попадёт в логи прокси и
      // в историю запросов.
      "x-goog-api-key": apiKey,
    },
    body: JSON.stringify({
      // Системная инструкция у Gemini — отдельное поле, а не первое
      // сообщение диалога: правила ответа не должны выглядеть репликой,
      // которую модель вправе продолжить.
      systemInstruction: { parts: [{ text: req.system }] },
      contents: [{ role: "user", parts: [{ text: req.user }] }],
      generationConfig: {
        temperature: req.temperature,
        ...(req.json ? { responseMimeType: "application/json" } : {}),
        ...(req.maxTokens && req.maxTokens > 0 ? { maxOutputTokens: req.maxTokens } : {}),
      },
    }),
    signal,
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`LLM HTTP ${res.status}: ${body.slice(0, 500)}`);
  }

  const data = await res.json();

  // Отказ по фильтрам приходит БЕЗ кандидатов и с причиной в
  // promptFeedback. Без этой ветки он выглядел бы как «пустой ответ», и
  // чинить пошли бы не туда.
  const blocked = data?.promptFeedback?.blockReason;
  if (blocked) {
    throw new Error(`Gemini отклонил запрос: blockReason=${blocked}`);
  }

  const candidate = data?.candidates?.[0];
  const parts = candidate?.content?.parts;
  const text = Array.isArray(parts)
    ? parts.map((p: { text?: string }) => p?.text ?? "").join("")
    : "";
  const finishReason = candidate?.finishReason;

  // MAX_TOKENS — это не «модель ответила ерундой», а «не успела
  // договорить». Разница принципиальная: первое чинится разбором ответа,
  // второе только потолком токенов, и путать их значит чинить не то.
  if (finishReason === "MAX_TOKENS") {
    throw new Error(truncatedMessage(text, req.maxTokens, "finishReason=MAX_TOKENS"));
  }

  if (text.trim().length === 0) {
    // finishReason здесь важнее самого факта пустоты: SAFETY и RECITATION
    // чинятся по-разному, а выглядят одинаково.
    const reason = finishReason ?? "нет кандидатов";
    throw new Error(`LLM вернул пустой ответ (finishReason=${reason})`);
  }
  return text;
}

async function callOpenAiCompatible(
  apiKey: string,
  model: string,
  req: ChatRequest,
  signal: AbortSignal,
): Promise<string> {
  const res = await fetch(`${llmBaseUrl()}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      messages: [
        { role: "system", content: req.system },
        { role: "user", content: req.user },
      ],
      // Явно нестриминговый ответ: нужен один цельный JSON-объект, а не
      // поток чанков (некоторые провайдеры включают стриминг сами, если
      // поле не передано вовсе).
      stream: false,
      ...(req.json ? { response_format: { type: "json_object" } } : {}),
      ...(req.maxTokens && req.maxTokens > 0 ? { max_tokens: req.maxTokens } : {}),
      temperature: req.temperature,
    }),
    signal,
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`LLM HTTP ${res.status}: ${body.slice(0, 500)}`);
  }

  const data = await res.json();
  const choice = data?.choices?.[0];
  const content = choice?.message?.content;
  const finishReason = choice?.finish_reason;

  if (finishReason === "length") {
    const shown = typeof content === "string" ? content : "";
    throw new Error(truncatedMessage(shown, req.maxTokens, "finish_reason=length"));
  }
  if (typeof content !== "string") {
    throw new Error(`LLM response missing message content: ${JSON.stringify(data).slice(0, 400)}`);
  }
  if (content.trim().length === 0) {
    // Пустой content при непустых рассуждениях — тот же симптом нехватки
    // бюджета у рассуждающей модели.
    const reasoning = choice?.message?.reasoning_content;
    throw new Error(
      `модель вернула пустой ответ (finish_reason=${finishReason}` +
        (typeof reasoning === "string" ? `, рассуждений ${reasoning.length} символов` : "") +
        ")",
    );
  }
  return content;
}

/** Одинаковое сообщение об обрезанном ответе для обоих провайдеров. */
function truncatedMessage(partial: string, maxTokens: number | undefined, reason: string): string {
  const shown = partial.length > 0 ? partial.slice(0, 200) : "(пусто)";
  const limit = maxTokens && maxTokens > 0 ? `, наш потолок=${maxTokens}` : ", наш потолок не задан";
  return `ответ обрезан провайдером по длине (${reason}${limit}), успело прийти: ${shown}`;
}
