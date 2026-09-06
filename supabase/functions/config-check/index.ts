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

import { bcp47For } from "../_shared/languages.ts";
import { googleKey, googleKeySource, missingKeyMessage } from "../_shared/googleKey.ts";
import { omniConfigDebug, omniEnabled, omniEvaluate } from "../_shared/omniJudge.ts";
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

/**
 * Проверка мультимодальной модели ЖИВЫМ вызовом.
 *
 * Отдельная функция, а не строчка в блоке llm: это другой провайдер, другой
 * ключ и другой протокол. И проверить его иначе нельзя — у сервиса нет
 * эндпоинта «просто скажи, что ключ верный», а ошибка в ключе выглядит как
 * обычный HTTP 401 в середине разбора речи, то есть всплывает уже в игре.
 *
 * Шлём короткую тишину: содержимое звука неважно, важно, что запрос дошёл,
 * ключ принят и ответ разобрался. Модель на тишине честно вернёт пустое
 * «услышанное» — этого достаточно.
 */
async function checkOmni(): Promise<CheckResult> {
  if (!omniEnabled()) {
    return {
      configured: false,
      reachable: null,
      detail: "мультимодальный путь выключен (OMNI_ENABLED != 1) — " +
        "речь разбирают распознавание и судья по отдельности",
    };
  }

  const result = await omniEvaluate({
    audio: silentWav(),
    audioFormat: "wav",
    nativeLanguage: "ru",
    targetLanguage: "en",
    // Задание пустое: содержимое неважно, важно, что запрос дошёл, ключ
    // принят и ответ разобрался.
    prompt: "",
    level: "A1",
    budgetMs: 60_000,
  });

  return result.degraded
    ? {
      configured: true,
      reachable: false,
      detail: `${JSON.stringify(omniConfigDebug())}: ${result.failureReason ?? "неизвестная причина"}`,
    }
    : {
      configured: true,
      reachable: true,
      detail: `${omniConfigDebug().model} отвечает, ключ принят`,
    };
}

/** Секунда тишины в WAV 16 кГц моно — минимальный корректный контейнер. */
function silentWav(): Uint8Array {
  const samples = 16_000;
  const bytes = new Uint8Array(44 + samples * 2);
  const view = new DataView(bytes.buffer);
  const ascii = (offset: number, text: string) => {
    for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i));
  };
  ascii(0, "RIFF");
  view.setUint32(4, 36 + samples * 2, true);
  ascii(8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 16_000, true);
  view.setUint32(28, 32_000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, "data");
  view.setUint32(40, samples * 2, true);
  return bytes;
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

  const [tts, omni] = await Promise.all([checkTts(), checkOmni()]);

  // Готовность = разбор ответов работает. Проверять больше нечего:
  // распознавание и текстовый судья удалены, речь целиком разбирает
  // мультимодальная модель.
  //
  // Озвучка в готовность не входит: без неё играть можно, просто нельзя
  // послушать образец. Валить общий ready из-за неё значило бы прятать
  // настоящую поломку за необязательной.
  const ready = omni.configured && omni.reachable !== false;

  return new Response(
    JSON.stringify(
      {
        ready,
        omni,
        tts: { key_from: googleKeySource("tts"), ...tts },
        hint: ready
          ? "Ключ принят, модель отвечает." +
            (tts.reachable === true ? "" : " Озвучка при этом не работает — смотрите блок tts.")
          : "Смотрите detail у блока omni.",
      },
      null,
      2,
    ),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});

