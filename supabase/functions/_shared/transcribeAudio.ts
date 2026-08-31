// Провайдер-агностичный ASR-адаптер — серверная замена встроенному в ОС
// распознаванию речи (пакет speech_to_text), от которого проект отказался.
//
// ПОЧЕМУ ASR переехал на сервер. Клиент писал аудио пакетом record и
// ОДНОВРЕМЕННО слушал микрофон системным распознавателем через
// speech_to_text. На Android это не работает: AudioRecord (record) и
// SpeechRecognizer (speech_to_text) конкурируют за один и тот же вход, и
// тот, кто пришёл вторым, не получает звук вообще. Транскрипт всегда
// оказывался пустым, из-за чего evaluate-recording уходил в ветку
// "пустой транскрипт" и НИ РАЗУ не доходил до LLM — игрок видел балл 1 и
// "ошибок не найдено" что бы он ни сказал. Теперь клиент только пишет
// файл, а речь распознаётся здесь, по загруженному аудио.
//
// Как и в evaluateGrammar.ts, смена провайдера — это правка переменных
// окружения Edge Function, а не кода:
//   ASR_PROVIDER    google (по умолчанию) | openai
//   ASR_API_KEY     ключ провайдера
//   ASR_BASE_URL    переопределение эндпоинта (обычно не нужно)
//   ASR_MODEL       google: latest_long (по умолчанию); openai: whisper-1
//   ASR_DETECT_LANGUAGE  1 (по умолчанию) — просить Google определить язык
//                   и ловить ответ не на том языке; 0 — прежнее поведение
//   ASR_TIMEOUT_MS  таймаут запроса, по умолчанию 60000
//
// Провайдер openai — это любой эндпоинт с whisper-совместимым
// /audio/transcriptions (в том числе тот же base_url, что у LLM-судьи),
// он нужен как запасной путь, если Google Cloud окажется недоступен.

export interface TranscribedWord {
  word: string;
  confidence: number;
}

export interface TranscriptionResult {
  /** Распознанный текст. Пустая строка = провайдер отработал, но речи не услышал. */
  transcript: string;
  /** Общая уверенность распознавания 0..1 (0, если провайдер её не сообщил). */
  confidence: number;
  words: TranscribedWord[];
  /**
   * На каком языке, по мнению самого распознавателя, говорили. Код языка
   * приложения ('ru'/'en'/'es') или null, если провайдер не сказал.
   *
   * Это не наша догадка, а поле ответа Google (`results[].languageCode`),
   * которое появляется, когда в запрос переданы alternativeLanguageCodes.
   * Придумывать собственное определение языка не пришлось.
   */
  detectedLanguage: string | null;
  /**
   * true — распознать НЕ УДАЛОСЬ по нашей вине (сбой/таймаут/не настроен
   * ключ). Это принципиально не то же самое, что пустой transcript при
   * degraded=false: там игрок действительно промолчал, и балл 1 честен, а
   * здесь штрафовать игрока за нашу поломку нельзя.
   */
  degraded: boolean;

  /** Техническая диагностика для отладочной панели в игре (миграция 0016). */
  debug: Record<string, unknown>;
}

/** Язык приложения -> BCP-47, который ждут облачные ASR. */
const BCP47_BY_LANGUAGE: Record<string, string> = {
  en: "en-US",
  es: "es-ES",
  ru: "ru-RU",
};

export function bcp47For(languageCode: string): string {
  return BCP47_BY_LANGUAGE[languageCode] ?? "en-US";
}

/** Обратно: 'en-US' (или просто 'en') -> 'en'. Регистр Google не гарантирует. */
export function languageFromBcp47(tag: string | null | undefined): string | null {
  if (typeof tag !== "string" || tag.length === 0) return null;
  const base = tag.split("-")[0].toLowerCase();
  return base in BCP47_BY_LANGUAGE ? base : null;
}

/**
 * Письменность языка. Нужна ровно для одного вопроса — «это точно НЕ тот
 * язык?» — и ни для чего больше.
 */
const SCRIPT_BY_LANGUAGE: Record<string, "cyrillic" | "latin"> = {
  en: "latin",
  es: "latin",
  ru: "cyrillic",
};

const CYRILLIC = /[\u0400-\u04FF]/;
const LATIN = /[A-Za-z\u00C0-\u024F]/;

/**
 * Точно ли этот текст НЕ на языке [target].
 *
 * Отвечает только «нет» и «не знаю» — определять, что за язык на самом
 * деле, здесь никто не пытается: это работа распознавателя, и он её уже
 * сделал (см. detectedLanguage). Функция — страховка на случай, когда
 * провайдер язык не сообщил.
 *
 * Проверка одна и стоит микросекунды: письменность. Кириллица там, где
 * ждали английский, — это ответ на другом языке, и другого объяснения у
 * этого быть не может. Обратное тоже верно. Английский от испанского так
 * не отличить (обе латиница) — и не надо: в этом случае функция честно
 * говорит "не знаю", а не выдумывает ответ.
 */
export function definitelyNotLanguage(text: string, target: string): boolean {
  const expected = SCRIPT_BY_LANGUAGE[target];
  if (!expected) return false;
  const hasCyrillic = CYRILLIC.test(text);
  const hasLatin = LATIN.test(text);
  if (expected === "latin") return hasCyrillic && !hasLatin;
  return hasLatin && !hasCyrillic;
}

/**
 * Таймаут запроса к ASR. Он НЕ ограничивает длину записи — только не даёт
 * зависшему провайдеру утащить за собой всю задачу: без таймаута функцию
 * убивает платформа ДО блока catch, и задача остаётся в 'processing'
 * навсегда. Поэтому он щедрый и настраивается.
 */
const ASR_TIMEOUT_MS = Number(Deno.env.get("ASR_TIMEOUT_MS") ?? 60_000);

function empty(debug: Record<string, unknown>): TranscriptionResult {
  return {
    transcript: "",
    confidence: 0,
    words: [],
    detectedLanguage: null,
    degraded: false,
    debug: { ...debug, status: "empty" },
  };
}

function failed(reason: string, debug: Record<string, unknown> = {}): TranscriptionResult {
  console.error("transcribeAudio:", reason);
  return {
    transcript: "",
    confidence: 0,
    words: [],
    detectedLanguage: null,
    degraded: true,
    debug: { ...debug, status: "failed", error: reason },
  };
}

/**
 * Разбор WAV-контейнера, который пишет клиент (record, AudioEncoder.wav).
 *
 * Google STT принимает и файл целиком (тогда encoding/sampleRateHertz
 * определяются по заголовку), но полагаться на автоопределение незачем:
 * заголовок разбирается тривиально, а взамен мы точно знаем реальную
 * частоту дискретизации устройства — она может отличаться от запрошенной,
 * если железо не умеет 16 кГц, и тогда автоопределение спасёт, а жёстко
 * зашитые 16000 испортили бы распознавание.
 */
interface WavData {
  pcm: Uint8Array;
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
}

export function parseWav(bytes: Uint8Array): WavData | null {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (offset: number) =>
    String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]);

  if (bytes.byteLength < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") return null;

  let sampleRate = 0;
  let channels = 0;
  let bitsPerSample = 0;
  let pcm: Uint8Array | null = null;

  // Чанки идут подряд: 4 байта имени, 4 байта длины, дальше данные с
  // выравниванием до чётного размера. Между fmt и data может лежать что
  // угодно (LIST/fact) — поэтому идём циклом, а не по фиксированным
  // смещениям "как обычно бывает".
  let offset = 12;
  while (offset + 8 <= bytes.byteLength) {
    const id = tag(offset);
    const size = view.getUint32(offset + 4, true);
    const body = offset + 8;

    if (id === "fmt " && body + 16 <= bytes.byteLength) {
      channels = view.getUint16(body + 2, true);
      sampleRate = view.getUint32(body + 4, true);
      bitsPerSample = view.getUint16(body + 14, true);
    } else if (id === "data") {
      const end = Math.min(body + size, bytes.byteLength);
      pcm = bytes.subarray(body, end);
      break;
    }

    offset = body + size + (size % 2);
  }

  if (!pcm || sampleRate === 0 || channels === 0) return null;
  return { pcm, sampleRate, channels, bitsPerSample };
}

/** base64 без промежуточной строки на каждый байт — записи бывают под мегабайт. */
function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.byteLength; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") {
      throw new Error(`ASR request timed out after ${Math.round(timeoutMs / 1000)}s`);
    }
    throw e;
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Google Cloud Speech-to-Text v1, синхронный speech:recognize.
 *
 * ЕДИНСТВЕННОЕ оставшееся ограничение на длину — платформенное: синхронный
 * speech:recognize принимает не больше минуты аудио. Снять его правкой
 * параметров нельзя, для более длинных записей нужен асинхронный
 * longrunningrecognize (запрос + опрос операции). Голосовое в раунде —
 * секунды, поэтому этот путь пока не нужен; если записи станут длиннее
 * минуты, провайдер вернёт понятную ошибку, и она попадёт в отладочную
 * панель.
 */
async function transcribeGoogle(
  audio: Uint8Array,
  languageCode: string,
  alternativeLanguages: string[],
  apiKey: string,
  hintPhrases: string[],
  timeoutMs: number,
): Promise<TranscriptionResult> {
  const baseUrl = Deno.env.get("ASR_BASE_URL") ?? "https://speech.googleapis.com/v1";
  // latest_long, а НЕ latest_short. Короткая модель рассчитана на команды и
  // отдельные реплики в пару секунд; фраза раунда — пять предложений и
  // секунд двадцать речи, и на ней short-модель обрывает распознавание на
  // середине. Ровно то, что выглядело как «распознаёт не всё, что я сказал».
  const model = Deno.env.get("ASR_MODEL") ?? "latest_long";

  // Определение языка можно выключить одной переменной окружения, не
  // трогая код. Оно нужно на всякий случай: alternativeLanguageCodes у
  // Google описан как рассчитанный на короткие реплики ("voice command and
  // voice search"), а фраза раунда — абзац. Если окажется, что на наших
  // записях он портит обычное распознавание, выключение вернёт прежнее
  // поведение, а проверка «не тот язык» продолжит работать по письменности
  // (definitelyNotLanguage).
  const detectionEnabled = (Deno.env.get("ASR_DETECT_LANGUAGE") ?? "1") !== "0";
  const alternatives = !detectionEnabled ? [] : alternativeLanguages
    .filter((code) => code !== languageCode && code in BCP47_BY_LANGUAGE)
    .slice(0, 3)
    .map(bcp47For);

  const meta = {
    provider: "google",
    model,
    language: bcp47For(languageCode),
    alternative_languages: alternatives,
    audio_bytes: audio.byteLength,
  };
  const startedAt = Date.now();

  const wav = parseWav(audio);
  if (!wav) return failed("audio is not a parseable WAV container", meta);

  const res = await fetchWithTimeout(`${baseUrl}/speech:recognize?key=${encodeURIComponent(apiKey)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      config: {
        encoding: "LINEAR16",
        sampleRateHertz: wav.sampleRate,
        audioChannelCount: wav.channels,
        languageCode: bcp47For(languageCode),
        // Распознаватель БОЛЬШЕ НЕ ЗАПЕРТ в одном языке.
        //
        // Раньше сюда уходил только целевой язык, и это была не настройка
        // качества, а жёсткое ограничение: Google обязан выдать текст на
        // заданном языке и ничего другого выдать не может. Игрок,
        // прочитавший русскую фразу вслух вместо перевода, получал не
        // «не тот язык», а набор английских слов, похожих по звучанию на
        // его русские, — и судья разбирал эту бессмыслицу всерьёз.
        //
        // Теперь родной язык игрока идёт альтернативой, и провайдер сам
        // сообщает в ответе, что он в итоге услышал (results[].languageCode).
        // Целевой язык остаётся ОСНОВНЫМ: он ожидаемый, а Google прямо
        // рекомендует держать список альтернатив минимальным — чем их
        // больше, тем чаще он ошибается с выбором.
        ...(alternatives.length > 0 ? { alternativeLanguageCodes: alternatives } : {}),
        model,
        // useEnhanced здесь НЕТ намеренно, не забыли. Улучшенные модели у
        // Google — это ровно две, phone_call и video; для latest_long
        // улучшенной версии не существует, и флаг молча откатывается на
        // стандартную. То есть он ничего не делал, а комментарий рядом с
        // ним обещал прибавку точности на акценте, которой не было.
        enableAutomaticPunctuation: true,
        enableWordConfidence: true,
        // Учащийся говорит с акцентом и ошибается — распознавание не должно
        // "чинить" его речь под ближайшую правильную фразу, иначе судья
        // получит текст без тех самых ошибок, которые он должен найти.
        profanityFilter: false,
        // Подсказка распознавателю: мы ТОЧНО знаем, какую фразу игрок
        // сейчас повторяет. Без неё распознаватель угадывает слова из всего
        // языка сразу и на акценте ошибается; с ней он выбирает между
        // похожими вариантами в пользу ожидаемых слов.
        //
        // boost намеренно умеренный (10, а не максимум): при слишком
        // сильном подталкивании распознаватель начинает «слышать»
        // ожидаемую фразу там, где игрок сказал иначе, и судья перестаёт
        // видеть настоящие ошибки — то есть режим обучения ломается.
        ...(hintPhrases.length > 0
          ? { speechContexts: [{ phrases: hintPhrases.slice(0, 500), boost: 10 }] }
          : {}),
      },
      audio: { content: toBase64(wav.pcm) },
    }),
  }, timeoutMs);

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    return failed(`Google STT HTTP ${res.status}: ${body.slice(0, 500)}`, {
      ...meta,
      elapsed_ms: Date.now() - startedAt,
      audio_seconds: Math.round((wav.pcm.byteLength / (wav.sampleRate * wav.channels * 2)) * 10) / 10,
    });
  }

  const data = await res.json();
  const audioSeconds = Math.round((wav.pcm.byteLength / (wav.sampleRate * wav.channels * 2)) * 10) / 10;
  const base = { ...meta, elapsed_ms: Date.now() - startedAt, audio_seconds: audioSeconds, hints: hintPhrases.length };

  const results = Array.isArray(data?.results) ? data.results : [];
  if (results.length === 0) return empty(base);

  const parts: string[] = [];
  const words: TranscribedWord[] = [];
  const detected: string[] = [];
  let confidenceSum = 0;
  let confidenceCount = 0;

  for (const result of results) {
    // Язык, который распознаватель выбрал для ЭТОГО куска. Пишется только
    // когда в запросе были альтернативы; берём первый непустой.
    const resultLanguage = languageFromBcp47(result?.languageCode);
    if (resultLanguage) detected.push(resultLanguage);
    const alternative = result?.alternatives?.[0];
    if (!alternative) continue;
    if (typeof alternative.transcript === "string") parts.push(alternative.transcript.trim());
    if (typeof alternative.confidence === "number") {
      confidenceSum += alternative.confidence;
      confidenceCount++;
    }
    for (const w of alternative.words ?? []) {
      if (typeof w?.word !== "string") continue;
      words.push({ word: w.word, confidence: typeof w.confidence === "number" ? w.confidence : 0 });
    }
  }

  const transcript = parts.filter((p) => p.length > 0).join(" ").trim();
  if (transcript.length === 0) return empty(base);

  const confidence = confidenceCount > 0 ? confidenceSum / confidenceCount : 0;
  const detectedLanguage = detected[0] ?? null;
  return {
    transcript,
    confidence,
    words,
    detectedLanguage,
    degraded: false,
    debug: {
      ...base,
      status: "ok",
      transcript,
      confidence: Math.round(confidence * 100) / 100,
      detected_language: detectedLanguage,
    },
  };
}

/**
 * Whisper-совместимый /audio/transcriptions (OpenAI и все, кто повторяет
 * его формат). Пословной уверенности здесь нет — заполняем её нулями, поле
 * в схеме всё равно задел на будущее и в расчёте балла не участвует.
 */
async function transcribeOpenAi(
  audio: Uint8Array,
  languageCode: string,
  apiKey: string,
  timeoutMs: number,
): Promise<TranscriptionResult> {
  const baseUrl = Deno.env.get("ASR_BASE_URL") ?? Deno.env.get("LLM_BASE_URL") ?? "https://api.openai.com/v1";
  const model = Deno.env.get("ASR_MODEL") ?? "whisper-1";

  const meta = { provider: "openai", model, language: languageCode, audio_bytes: audio.byteLength };
  const startedAt = Date.now();

  const form = new FormData();
  form.append("file", new Blob([audio], { type: "audio/wav" }), "recording.wav");
  form.append("model", model);
  form.append("language", languageCode);
  form.append("response_format", "json");

  const res = await fetchWithTimeout(`${baseUrl}/audio/transcriptions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
  }, timeoutMs);

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    return failed(`ASR HTTP ${res.status}: ${body.slice(0, 500)}`, { ...meta, elapsed_ms: Date.now() - startedAt });
  }

  const data = await res.json();
  const base = { ...meta, elapsed_ms: Date.now() - startedAt };
  const transcript = typeof data?.text === "string" ? data.text.trim() : "";
  if (transcript.length === 0) return empty(base);

  return {
    transcript,
    confidence: 0,
    words: transcript.split(/\s+/).map((word: string) => ({ word, confidence: 0 })),
    // Whisper язык определяет, но при заданном language его не возвращает;
    // тут работает только запасная проверка по письменности.
    detectedLanguage: null,
    degraded: false,
    debug: { ...base, status: "ok", transcript },
  };
}

/**
 * transcribeAudio(audio, languageCode) -> { transcript, words, degraded }
 *
 * Никогда не бросает: сбой провайдера — это degraded=true, а не падение
 * воркера. Иначе задача в evaluation_jobs осталась бы висеть, а клиент —
 * ждать результат, которого не будет.
 */
export async function transcribeAudio(
  audio: Uint8Array,
  languageCode: string,
  /**
   * Фразы-подсказки для распознавателя — обычно та самая фраза раунда,
   * которую игрок сейчас повторяет. Сильно повышает точность на речи
   * неносителя; см. speechContexts в transcribeGoogle.
   */
  hintPhrases: string[] = [],
  /**
   * На каких ещё языках игрок мог заговорить — обычно его родной. Не
   * «улучшение качества», а способ вообще узнать, что он ответил не на том
   * языке: без этого списка провайдер обязан выдать текст на целевом языке
   * и о чужой речи промолчит.
   */
  alternativeLanguages: string[] = [],
  /**
   * Сколько времени осталось у воркера на распознавание. Собственный
   * ASR_TIMEOUT_MS остаётся верхней границей, но пережить бюджет задачи он
   * не может: воркера убивают снаружи, и тогда результат не запишет никто.
   */
  budgetMs: number = ASR_TIMEOUT_MS,
): Promise<TranscriptionResult> {
  const provider = (Deno.env.get("ASR_PROVIDER") ?? "google").toLowerCase();
  const apiKey = Deno.env.get("ASR_API_KEY");
  if (!apiKey) return failed("ASR_API_KEY is not configured");
  if (audio.byteLength === 0) return failed("audio file is empty");
  const timeoutMs = Math.max(3_000, Math.min(ASR_TIMEOUT_MS, budgetMs));

  try {
    switch (provider) {
      case "google":
        return await transcribeGoogle(
          audio,
          languageCode,
          alternativeLanguages,
          apiKey,
          hintPhrases,
          timeoutMs,
        );
      case "openai":
        return await transcribeOpenAi(audio, languageCode, apiKey, timeoutMs);
      default:
        return failed(`unknown ASR_PROVIDER "${provider}" (expected "google" or "openai")`);
    }
  } catch (e) {
    return failed(`provider ${provider} threw: ${e}`);
  }
}
