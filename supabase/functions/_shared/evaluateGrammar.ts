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

  /** Почему не получилось — только при degraded. Для логов и config-check. */
  failureReason?: string;

  /** Техническая диагностика для отладочной панели в игре (миграция 0016). */
  debug: Record<string, unknown>;
}

/**
 * Нейтральный балл при неустранимом сбое НАШЕЙ стороны (модель не ответила,
 * ASR не смог распознать) — игрока за свою поломку не штрафуем. Экспортирован,
 * потому что тем же баллом заканчивается сбой распознавания речи в
 * evaluate-recording (см. transcribeAudio.ts).
 */
export const NEUTRAL_SCORE = 7;

/**
 * Потолок на число разбираемых ошибок.
 *
 * Фраза раунда — пять предложений (см. lib/data/phrase_bank.dart), и у
 * новичка ошибок в ней бывает больше десятка. Подробный режим просит 3-5
 * предложений объяснения НА КАЖДУЮ, то есть ответ разрастался до нескольких
 * тысяч токенов: он не влезал ни в таймаут, ни в max_tokens, а обрезанный
 * JSON невалиден целиком — судья деградировал, и игрок видел нейтральные 7
 * баллов без единого разбора.
 *
 * Пять ошибок — это ещё и то, что человек реально способен исправить между
 * двумя попытками подряд; список из пятнадцати не помог бы ему всё равно.
 */
const MAX_REPORTED_ERRORS = 5;

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
Если ошибок нет — верни {"score": 10, "errors": []}.

ВАЖНО: включай в errors НЕ БОЛЕЕ ${MAX_REPORTED_ERRORS} ошибок — самые грубые и самые важные для
понимания. Балл (score) при этом выставляй по ВСЕЙ фразе целиком, учитывая и те ошибки, которые
в список не попали.`;

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

/**
 * ДИАГНОСТИЧЕСКИЙ РЕЖИМ. Включается переменной окружения LLM_TRIVIAL_PROBE=1
 * и подменяет весь промпт на просьбу вернуть один и тот же ответ независимо
 * от того, что сказал игрок.
 *
 * Зачем: обычный промпт заставляет модель писать 3-5 предложений разбора на
 * каждую ошибку, и по одному лишь таймауту невозможно понять, ДОЛГО ЛИ ОНА
 * ДУМАЕТ или мы до неё вообще не достучались — симптом в обоих случаях
 * одинаковый. С тривиальным промптом генерировать почти нечего: если ответ
 * приходит быстро, дело в объёме генерации; если и он не приходит — дело в
 * связи с провайдером.
 *
 * ВРЕМЕННЫЙ инструмент. Пока включён, судья НЕ РАБОТАЕТ: он всем ставит
 * балл 1 и не находит ошибок. Не оставлять включённым — поэтому и логируется
 * предупреждением на каждый вызов, и показывается в config-check.
 */
export function trivialProbeEnabled(): boolean {
  const raw = (Deno.env.get("LLM_TRIVIAL_PROBE") ?? "").toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes";
}

const TRIVIAL_SYSTEM_PROMPT =
  `Отвечай СТРОГО одним и тем же JSON, что бы тебе ни прислали, без markdown и без пояснений:
{"score": 1, "errors": []}`;

function buildSystemPrompt(detailed: boolean, level: CefrLevel): string {
  if (trivialProbeEnabled()) return TRIVIAL_SYSTEM_PROMPT;
  const levelBlock = `${LEVEL_INSTRUCTIONS[level]}\n${LEVEL_SCORE_REMINDER}`;
  return `${BASE_SYSTEM_PROMPT}\n${levelBlock}\n${detailed ? DETAILED_MESSAGE_INSTRUCTION : BRIEF_MESSAGE_INSTRUCTION}`;
}

function buildUserPrompt(transcript: string, targetLanguage: string, nativeLanguage: string): string {
  // В диагностическом режиме сам транскрипт не важен — важна только
  // скорость обмена репликами.
  if (trivialProbeEnabled()) return "ping";
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

  // Страховка на случай, если модель проигнорирует потолок из промпта:
  // показать игроку двадцать разборов сразу всё равно нельзя, а обрезать
  // здесь дешевле, чем гадать, почему экран не помещается.
  return { score, errors: errors.slice(0, MAX_REPORTED_ERRORS) };
}

/**
 * Достаёт JSON-объект из ответа модели.
 *
 * Прямой `JSON.parse` тут недостаточен: модели регулярно оборачивают ответ
 * в markdown-блок ```json ... ``` или добавляют строчку вежливости до/после
 * объекта — даже когда их об этом явно просили не делать, и даже когда
 * запрошен response_format. Раньше такой ответ считался невалидным, обе
 * попытки «падали», судья возвращал degraded, а игрок видел «ошибок не
 * найдено» — то есть поломка выглядела как безупречный ответ.
 */
export function extractJson(content: string): unknown {
  const withoutFences = content
    .replace(/^\s*```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .trim();

  try {
    return JSON.parse(withoutFences);
  } catch {
    // Объект внутри произвольного текста: берём от первой { до последней }.
    const start = withoutFences.indexOf("{");
    const end = withoutFences.lastIndexOf("}");
    if (start === -1 || end <= start) {
      throw new Error(`no JSON object in model response: ${content.slice(0, 300)}`);
    }
    return JSON.parse(withoutFences.slice(start, end + 1));
  }
}

/** Возвращает СЫРОЙ текст ответа модели — разбор и логирование выше по стеку. */
async function callLlmOnce(
  transcript: string,
  targetLanguage: string,
  nativeLanguage: string,
  detailed: boolean,
  level: CefrLevel,
  /**
   * false — повтор без `response_format` для провайдеров, которые этого
   * поля не знают и отвечают на него 400. Без такого отката судья у такого
   * провайдера не работал вообще, молча деградируя в «ошибок нет».
   */
  useResponseFormat: boolean,
): Promise<string> {
  const baseUrl = Deno.env.get("LLM_BASE_URL") ?? "https://api.b.ai/v1";
  const apiKey = Deno.env.get("LLM_API_KEY");
  // Значения по умолчанию у имени модели СОЗНАТЕЛЬНО нет. Раньше здесь
  // стояло "DeepSeek-V4-Flash" — модели с таким именем у провайдера не
  // существует, и каждый вызов судьи молча падал с model_not_found. Пусть
  // лучше отсутствие настройки будет явной ошибкой, чем «работающим»
  // значением, которое на самом деле не работает.
  const model = Deno.env.get("LLM_MODEL");

  if (!apiKey) {
    throw new Error("LLM_API_KEY is not configured");
  }
  if (!model) {
    throw new Error(
      "LLM_MODEL is not configured — задайте имя модели из списка провайдера: " +
        "npx supabase secrets set LLM_MODEL=<имя>",
    );
  }

  // Таймаут обязателен: без него зависший провайдер держит запрос до
  // убийства всей Edge Function платформой, а это происходит ДО
  // catch-блока — evaluation_jobs так и осталась бы в 'processing'
  // навсегда. С таймаутом fetch сам бросает исключение, которое ловит
  // retry-цикл evaluateGrammar.
  //
  // Но и слишком тесным он быть не может. Было 20 секунд — этого не
  // хватало: разбор для Одиночной Игры просит 3-5 предложений объяснения
  // НА КАЖДУЮ ошибку, и на нескольких ошибках модель просто не успевала
  // договорить. Судья упирался в таймаут все три раза подряд (в базе это
  // видно как задачи длительностью ~63 секунды = 3 x 20 c + распознавание)
  // и деградировал, а игрок видел «ИИ-судья не отвечает».
  const timeoutMs = Number(Deno.env.get("LLM_TIMEOUT_MS") ?? 45_000);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

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
        ...(useResponseFormat ? { response_format: { type: "json_object" } } : {}),
        // Потолок длины ответа. Без него модель на подробном режиме может
        // писать сколь угодно долго и упереться в таймаут, не договорив —
        // а недоговорённый JSON бесполезен целиком. Запаса хватает на
        // десяток подробных объяснений. В диагностическом режиме ответ
        // заведомо крошечный, и низкий потолок сам по себе исключает
        // «модель долго генерирует» из числа возможных причин.
        max_tokens: trivialProbeEnabled() ? 32 : 2000,
        temperature: 0.2,
      }),
      signal: controller.signal,
    });
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") {
      throw new Error(`LLM request timed out after ${Math.round(timeoutMs / 1000)}s`);
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
    throw new Error(`LLM response missing message content: ${JSON.stringify(data).slice(0, 400)}`);
  }
  return content;
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
  // Провайдер может не знать response_format и отвечать на него 400 — тогда
  // повторяем без него, иначе судья не работает вообще (и, что хуже,
  // молча: пустой список ошибок неотличим от «ошибок нет»).
  let useResponseFormat = true;
  const failures: string[] = [];

  if (trivialProbeEnabled()) {
    // Громко и на каждый вызов: в этом режиме оценки НЕТ, всем ставится
    // балл 1. Оставленный включённым, он выглядит как «судья работает, но
    // всё плохо» — а это ровно тот класс тихих поломок, из-за которого
    // здесь и появились transcript_status/judge_status.
    console.warn(
      "evaluateGrammar: ВКЛЮЧЁН ДИАГНОСТИЧЕСКИЙ РЕЖИМ LLM_TRIVIAL_PROBE — " +
        "промпт подменён, разбор не производится, балл всегда 1. " +
        "Выключить: npx supabase secrets unset LLM_TRIVIAL_PROBE",
    );
  }

  for (let attempt = 0; attempt < 3; attempt++) {
    const startedAt = Date.now();
    try {
      const raw = await callLlmOnce(
        transcript,
        targetLanguage,
        nativeLanguage,
        detailed,
        level,
        useResponseFormat,
      );
      const parsed = validate(extractJson(raw));
      if (parsed) {
        const elapsed = Date.now() - startedAt;
        // Время ответа в логах — чтобы «судья не отвечает» сразу отличалось
        // от «судья отвечает, но медленно» без раскопок по таблицам.
        console.log(`evaluateGrammar: ответ за ${elapsed} мс, ошибок ${parsed.errors.length}`);
        return {
          score: parsed.score,
          errors: parsed.errors,
          degraded: false,
          debug: {
            model: Deno.env.get("LLM_MODEL") ?? "(не задана)",
            status: "ok",
            attempt,
            elapsed_ms: elapsed,
            score: parsed.score,
            errors_count: parsed.errors.length,
            raw: raw.slice(0, 600),
          },
        };
      }
      // Разобрали JSON, но форма не та — покажем, что именно вернула модель,
      // иначе причина неотличима от сетевого сбоя.
      failures.push(`попытка ${attempt}: ответ разобран, но не той формы: ${raw.slice(0, 300)}`);
    } catch (e) {
      const message = String(e);
      failures.push(`попытка ${attempt} (${Date.now() - startedAt} мс): ${message.slice(0, 300)}`);

      // Неверная модель, неверный ключ, нет прав — повтор с тем же запросом
      // не поможет никогда, только сожжёт время работы функции и квоту.
      if (/model_not_found|does not exist|unknown model|HTTP 401|HTTP 403/i.test(message)) {
        break;
      }
      // Таймаут — тоже не повод повторять: модель не «сбойнула», она просто
      // не успевает, и второй такой же запрос не будет быстрее. Раньше три
      // таймаута подряд съедали больше минуты и всё равно заканчивались
      // деградацией — ровно то, что игрок видел как «судья не отвечает».
      if (/timed out/i.test(message)) {
        break;
      }
      if (useResponseFormat && /response_format|json_object|HTTP 4\d\d/i.test(message)) {
        useResponseFormat = false;
      }
    }
  }

  const reason = failures.join(" | ");
  console.error("evaluateGrammar: судья не дал результата:", reason);
  return {
    score: NEUTRAL_SCORE,
    errors: [],
    degraded: true,
    failureReason: reason,
    debug: {
      model: Deno.env.get("LLM_MODEL") ?? "(не задана)",
      base_url: Deno.env.get("LLM_BASE_URL") ?? "https://api.b.ai/v1",
      status: "degraded",
      attempts: failures.length,
      reason,
      transcript_length: transcript.length,
    },
  };
}
