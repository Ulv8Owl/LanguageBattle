// Диагностика конфигурации пайплайна оценки — отвечает на вопрос «всё ли
// настроено и работают ли ключи», не требуя гадать по логам и не показывая
// сами секреты.
//
// Проверяет ЖИВЫМИ запросами, а не только наличие переменных: ключ может
// быть задан, но просрочен, отозван или API у провайдера не включён — по
// одному лишь `Deno.env.get(...) !== undefined` это неотличимо.
//
// ДОСТУП: только по service_role key в заголовке Authorization. Anon-ключ
// лежит внутри установленного приложения у каждого игрока, поэтому пускать
// по нему сюда нельзя даже ради булевых флагов.
//
// Секретов в ответе нет и быть не должно: только длина и последние 4
// символа ключа — этого хватает, чтобы отличить «задан не тот ключ» от
// «ключ не задан», и недостаточно, чтобы им воспользоваться.

import { bcp47For } from "../_shared/asr/index.ts";
import { evaluateGrammar, trivialProbeEnabled } from "../_shared/evaluateGrammar.ts";
import { googleKey, googleKeySource, missingKeyMessage } from "../_shared/googleKey.ts";
import { llmBaseUrl, llmChat, llmModel, llmProvider } from "../_shared/llmChat.ts";
import { synthesizeSpeech } from "../_shared/tts.ts";

/// Заведомо ошибочная фраза: судья ОБЯЗАН найти здесь минимум одну ошибку
/// (He go -> He went / He goes). Если он возвращает пустой список — дело не
/// в связи с провайдером, а в том, что он не понимает задачу.
const JUDGE_PROBE = "He go to school yesterday and dont finish he homework";

interface CheckResult {
  configured: boolean;
  /** null, если проверка живым запросом не проводилась (нечего проверять). */
  reachable: boolean | null;
  detail: string;
}

/** Хвост ключа для сверки «тот ли ключ задан», без возможности его использовать. */
function fingerprint(value: string | undefined): string {
  if (!value) return "не задан";
  return `${value.length} символов, оканчивается на …${value.slice(-4)}`;
}

/** Односекундный WAV-тон: речи нет, но формат корректный — проверяем ключ, а не распознавание. */
function toneWavPcm(): Uint8Array {
  const sampleRate = 16000;
  const samples = sampleRate; // 1 секунда
  const pcm = new Uint8Array(samples * 2);
  const view = new DataView(pcm.buffer);
  for (let i = 0; i < samples; i++) {
    view.setInt16(i * 2, Math.round(3000 * Math.sin((2 * Math.PI * 220 * i) / sampleRate)), true);
  }
  return pcm;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.byteLength; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

async function withTimeout<T>(work: (signal: AbortSignal) => Promise<T>, ms = 15_000): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await work(controller.signal);
  } finally {
    clearTimeout(timer);
  }
}

async function checkAsr(): Promise<CheckResult> {
  const provider = (Deno.env.get("ASR_PROVIDER") ?? "google").toLowerCase();
  const apiKey = googleKey("asr");
  if (!apiKey) {
    return {
      configured: false,
      reachable: null,
      detail: `распознавание речи не заработает: ${missingKeyMessage("asr")}`,
    };
  }
  if (provider !== "google") {
    return {
      configured: true,
      reachable: null,
      detail: `ASR_PROVIDER=${provider}: живая проверка реализована только для google, ` +
        `ключ (${fingerprint(apiKey)}) задан`,
    };
  }

  const baseUrl = Deno.env.get("ASR_BASE_URL") ?? "https://speech.googleapis.com/v1";
  try {
    const res = await withTimeout((signal) =>
      fetch(`${baseUrl}/speech:recognize?key=${encodeURIComponent(apiKey)}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        signal,
        body: JSON.stringify({
          config: {
            encoding: "LINEAR16",
            sampleRateHertz: 16000,
            audioChannelCount: 1,
            languageCode: bcp47For("en"),
            model: Deno.env.get("ASR_MODEL") ?? "latest_long",
          },
          audio: { content: toBase64(toneWavPcm()) },
        }),
      })
    );
    if (res.ok) {
      return {
        configured: true,
        reachable: true,
        detail: `Google Speech-to-Text отвечает 200, ключ принят (${fingerprint(apiKey)})`,
      };
    }
    const body = await res.text().catch(() => "");
    return {
      configured: true,
      reachable: false,
      detail: `Google Speech-to-Text вернул HTTP ${res.status}: ${body.slice(0, 300)}`,
    };
  } catch (e) {
    return { configured: true, reachable: false, detail: `запрос не удался: ${e}` };
  }
}

async function checkLlm(): Promise<CheckResult> {
  const apiKey = googleKey("llm");
  if (!apiKey) {
    return {
      configured: false,
      reachable: null,
      detail: `судья и разбор ошибок не заработают: ${missingKeyMessage("llm")}`,
    };
  }

  const provider = llmProvider();
  const baseUrl = llmBaseUrl();
  const model = llmModel();
  if (!model) {
    return {
      configured: false,
      reachable: null,
      detail: "LLM_MODEL не задана — имя модели не подставляется по умолчанию намеренно: " +
        "несуществующее имя выглядело бы как рабочая настройка. " +
        "npx supabase secrets set LLM_MODEL=<имя>",
    };
  }

  // Живой запрос идёт ровно тем же путём, что и настоящий вызов, — иначе
  // проверка сообщала бы об исправности пути, которым никто не ходит.
  try {
    const answer = await withTimeout(async (signal) => {
      // llmChat собственный таймаут ставит сам; signal здесь нужен только
      // ради единообразия с остальными проверками.
      void signal;
      return await llmChat(apiKey, {
        system: "Отвечай строго JSON вида {\"ok\":true} и ничем больше.",
        user: "ping",
        json: true,
        temperature: 0,
        timeoutMs: 15_000,
        maxTokens: 64,
      });
    }, 20_000);
    return {
      configured: true,
      reachable: true,
      detail: `${provider} (${baseUrl}) отвечает на модель ${model}, ключ принят ` +
        `(${fingerprint(apiKey)}); ответ: ${answer.slice(0, 80)}`,
    };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    const result: CheckResult & { available_models?: string[] } = {
      configured: true,
      reachable: false,
      detail: `${provider} (${baseUrl}), модель ${model}: ${message.slice(0, 400)}`,
    };
    // Не та модель — самая частая причина отказа, и чинится она сменой
    // одной переменной. Спрашиваем у провайдера список, чтобы не заставлять
    // угадывать имя вслепую.
    if (/model_not_found|model.*does not exist|unknown model|not found|NOT_FOUND|404/i.test(message)) {
      result.available_models = provider === "gemini"
        ? await listGeminiModels(baseUrl, apiKey)
        : await listModels(baseUrl, apiKey);
      result.detail += ` — похоже, модель ${model} провайдер не знает. ` +
        "Выберите имя из available_models и задайте: npx supabase secrets set LLM_MODEL=<имя>";
    }
    return result;
  }
}

/** Список моделей Gemini — у него свой эндпоинт и своя форма ответа. */
async function listGeminiModels(baseUrl: string, apiKey: string): Promise<string[]> {
  try {
    const res = await withTimeout((signal) =>
      fetch(`${baseUrl}/models`, { headers: { "x-goog-api-key": apiKey }, signal })
    );
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      return [`не удалось получить список моделей: HTTP ${res.status}: ${body.slice(0, 200)}`];
    }
    const data = await res.json();
    const items = Array.isArray(data?.models) ? data.models : [];
    // Имя приходит как "models/gemini-...", а в LLM_MODEL нужна часть без
    // префикса — иначе подставленное из подсказки имя не сработает.
    const names = items
      .map((m: { name?: string }) => (m?.name ?? "").replace(/^models\//, ""))
      .filter((n: string) => n.length > 0);
    return names.length > 0 ? names : ["провайдер вернул пустой список моделей"];
  } catch (e) {
    return [`не удалось получить список моделей: ${e}`];
  }
}

/**
 * Синтез речи. Проверяется тем же вызовом, что и в игре, но на одном
 * слове: нам нужен ответ сервиса, а не аудио.
 */
async function checkTts(): Promise<CheckResult> {
  const apiKey = googleKey("tts");
  if (!apiKey) {
    return {
      configured: false,
      reachable: null,
      detail: `озвучка в разборе не заработает: ${missingKeyMessage("tts")}`,
    };
  }
  try {
    const result = await synthesizeSpeech("test", "en", 15_000);
    return {
      configured: true,
      reachable: true,
      detail: `Google Text-to-Speech отвечает, ключ принят (${fingerprint(apiKey)}), ` +
        `аудио ${result.audioContent.length} символов base64`,
    };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return { configured: true, reachable: false, detail: message.slice(0, 400) };
  }
}

/** Список моделей провайдера — только имена, для подсказки в ответе. */
async function listModels(baseUrl: string, apiKey: string): Promise<string[]> {
  try {
    const res = await withTimeout((signal) =>
      fetch(`${baseUrl}/models`, { headers: { Authorization: `Bearer ${apiKey}` }, signal })
    );
    if (!res.ok) return [`не удалось получить список моделей: HTTP ${res.status}`];
    const data = await res.json();
    const items = Array.isArray(data?.data) ? data.data : Array.isArray(data) ? data : [];
    const names = items
      .map((m: unknown) => (typeof m === "string" ? m : (m as { id?: string })?.id))
      .filter((id: unknown): id is string => typeof id === "string");
    if (names.length === 0) return ["провайдер вернул пустой список моделей"];
    // Модели для рассуждений/чата — то, что нам нужно; список у
    // распределителей бывает на сотни позиций, поэтому поднимаем наверх
    // похожие на подходящие, но показываем и остальные.
    const likely = names.filter((n: string) => /deepseek|qwen|gpt|claude|mistral|llama|gemini|glm/i.test(n));
    return [...new Set([...likely, ...names])].slice(0, 60);
  } catch (e) {
    return [`не удалось получить список моделей: ${e}`];
  }
}

/**
 * Прогон НАСТОЯЩЕГО судьи на заведомо ошибочной фразе — тем же кодом, что
 * работает в бою. Отличает три разных «LLM не работает»:
 * связь есть, но модель не отвечает форматом; связи нет; всё работает, но
 * модель не находит ошибок.
 */
async function checkJudge(): Promise<CheckResult & { probe?: unknown }> {
  if (!Deno.env.get("LLM_API_KEY")) {
    return { configured: false, reachable: null, detail: "LLM_API_KEY не задан — судью проверять нечем" };
  }

  const startedAt = Date.now();
  const result = await evaluateGrammar(JUDGE_PROBE, "en", "ru", "detailed", "A1");
  const elapsed = Date.now() - startedAt;

  // Диагностический режим меняет смысл всех остальных выводов этого блока,
  // поэтому о нём сообщаем первым делом и не притворяемся, что судья цел.
  if (trivialProbeEnabled()) {
    return {
      configured: true,
      reachable: !result.degraded,
      detail: result.degraded
        ? `ДИАГНОСТИЧЕСКИЙ РЕЖИМ: даже тривиальный ответ не получен за ${elapsed} мс — ` +
          `значит дело не в скорости генерации, а в связи с провайдером. ${result.failureReason ?? ""}`
        : `ДИАГНОСТИЧЕСКИЙ РЕЖИМ: тривиальный ответ получен за ${elapsed} мс — ` +
          "связь в порядке, значит обычный разбор упирается именно в объём генерации. " +
          "Судья сейчас НЕ оценивает: выключите режим (npx supabase secrets unset LLM_TRIVIAL_PROBE).",
      probe: { mode: "LLM_TRIVIAL_PROBE", elapsed_ms: elapsed, score: result.score },
    };
  }

  if (result.degraded) {
    return {
      configured: true,
      reachable: false,
      detail: `судья не дал разбора за ${elapsed} мс: ${result.failureReason ?? "причина не записана"}`,
      probe: { transcript: JUDGE_PROBE, elapsed_ms: elapsed },
    };
  }
  if (result.errors.length === 0) {
    return {
      configured: true,
      reachable: true,
      detail:
        "СВЯЗЬ ЕСТЬ, НО МОДЕЛЬ НЕ НАХОДИТ ОШИБОК в заведомо ошибочной фразе — " +
        `вернула score=${result.score} и пустой список. Похоже на слишком слабую модель: попробуйте другую через LLM_MODEL.`,
      probe: { transcript: JUDGE_PROBE, score: result.score, errors: [] },
    };
  }
  return {
    configured: true,
    reachable: true,
    detail: `судья работает: нашёл ошибок — ${result.errors.length}, балл ${result.score}, ответ за ${elapsed} мс`,
    probe: {
      transcript: JUDGE_PROBE,
      elapsed_ms: elapsed,
      score: result.score,
      errors: result.errors.map((e) => ({ message: e.message, replacement: e.replacement, category: e.category })),
    },
  };
}

/**
 * Роль из полезной нагрузки JWT — БЕЗ проверки подписи, и это здесь
 * безопасно: функция задеплоена с включённым verify_jwt (значение по
 * умолчанию), поэтому платформа уже проверила подпись ключом проекта до
 * входа в этот обработчик. Наше дело — отличить service_role от anon, а не
 * подтвердить подлинность токена заново.
 */
function jwtRole(token: string): string | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload = JSON.parse(atob(padded + "=".repeat((4 - (padded.length % 4)) % 4)));
    return typeof payload?.role === "string" ? payload.role : null;
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  const presented = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const role = jwtRole(presented);
  // Сравнение строк с SUPABASE_SERVICE_ROLE_KEY оставлено только запасным
  // путём: у проектов, переведённых на новые ключи (sb_secret_...), в
  // функцию подставляется НЕ тот же ключ, что показан в дашборде как
  // legacy service_role, и строгое равенство отвергало верный ключ.
  // Роль в JWT — то, что нас на самом деле интересует.
  const injected = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const authorised = role === "service_role" || (injected !== "" && presented === injected);

  if (!authorised) {
    return new Response(
      JSON.stringify({
        error: "нужен service_role key",
        // Подсказка без раскрытия секретов: показывает, ЧТО прислали.
        seen: presented === ""
          ? "заголовок Authorization пуст"
          : role === null
          ? "прислан не-JWT токен, и он не совпал с ключом функции"
          : `прислан токен с ролью "${role}" — нужен service_role`,
      }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  const [asr, llm, tts, judge] = await Promise.all([
    checkAsr(),
    checkLlm(),
    checkTts(),
    checkJudge(),
  ]);
  // Озвучка в готовность не входит: без неё играть можно, просто нельзя
  // послушать образец. Валить общий ready из-за неё значило бы прятать
  // настоящие поломки за необязательной.
  const blocks = [asr, llm, judge];
  const ready = blocks.every((b) => b.configured && b.reachable !== false);

  return new Response(
    JSON.stringify(
      {
        ready,
        asr: {
          provider: Deno.env.get("ASR_PROVIDER") ?? "google",
          key_from: googleKeySource("asr"),
          ...asr,
        },
        llm: {
          provider: llmProvider(),
          base_url: llmBaseUrl(),
          model: llmModel() ?? "(не задана)",
          key_from: googleKeySource("llm"),
          ...llm,
        },
        // llm выше проверяет только доступность эндпоинта; judge прогоняет
        // настоящий разбор — эндпоинт может отвечать 200, а судья при этом
        // не работать.
        judge,
        tts: { key_from: googleKeySource("tts"), ...tts },
        hint: ready
          ? "Ключи на месте, провайдеры отвечают, судья находит ошибки." +
            (tts.reachable === true ? "" : " Озвучка при этом не работает — смотрите блок tts.")
          : "Смотрите detail у того блока, где configured=false или reachable=false.",
      },
      null,
      2,
    ),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
