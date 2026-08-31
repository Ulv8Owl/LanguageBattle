import { languageFromTag } from "./languages.ts";
import { empty, failed, fetchWithTimeout, type TranscribedWord, type TranscriptionResult } from "./types.ts";

/**
 * Deepgram, /v1/listen.
 *
 * НЕ ПРОВАЙДЕР ПО УМОЛЧАНИЮ — этот файл существует и полностью готов к
 * работе (проверен на стенде с подменённым fetch, см. историю ветки
 * deepgram), но включается только явной переменной окружения
 * `ASR_PROVIDER=deepgram`. Пока по умолчанию стоит google — переключение
 * ничего в остальном коде не трогает: index.ts просто вызовет эту функцию
 * вместо transcribeGoogle.
 *
 * Почему он вообще здесь, а не только в другой ветке: цена (nova-3 —
 * порядка полцента за минуту против нескольких центов у Google) и
 * определение языка первого класса (`detect_language=true`, провайдер сам
 * сообщает, что услышал). Если Google начнёт хуже справляться с новыми
 * языками или подорожает, переключение — одна секретная переменная, а не
 * новый код.
 */
export async function transcribeDeepgram(
  audio: Uint8Array,
  languageCode: string,
  /**
   * Здесь не используется, и это осознанно. Deepgram определяет язык
   * сам (detect_language=true) и списка кандидатов не требует; параметр
   * оставлен, чтобы у всех провайдеров была одна сигнатура — Google без
   * него определять язык не умеет.
   */
  _alternativeLanguages: string[],
  apiKey: string,
  hintPhrases: string[],
  timeoutMs: number,
): Promise<TranscriptionResult> {
  const baseUrl = Deno.env.get("ASR_BASE_URL") ?? "https://api.deepgram.com/v1";
  const model = Deno.env.get("ASR_MODEL") ?? "nova-3";
  const detectionWanted = (Deno.env.get("ASR_DETECT_LANGUAGE") ?? "1") !== "0";

  /**
   * Запрос собирается двумя способами, и это не дублирование, а страховка.
   *
   * detect=false — минимальный запрос, который заведомо принимается:
   * модель и жёстко заданный язык, ровно как в примере из документации
   * Deepgram. detect=true — он же плюс определение языка.
   *
   * Определение языка — вещь полезная, но НЕ обязательная: без него игра
   * работает, без распознавания — нет. Поэтому если провайдер отверг
   * запрос с определением (4xx — «такого сочетания параметров нет»), мы
   * тут же повторяем минимальный. Расплата — молчание про «не тот язык»
   * до тех пор, пока сработает проверка по письменности; альтернатива —
   * полностью неработающее распознавание, что несравнимо хуже.
   */
  const buildParams = (detect: boolean): URLSearchParams => {
    const params = new URLSearchParams();
    params.set("model", model);
    params.set("punctuate", "true");
    if (detect) {
      // Именно detect_language=true — задокументированная форма. Список
      // языков (повторяющийся detect_language=en&detect_language=ru) в
      // документации тоже описан, но поддержан не всеми моделями, а у
      // nova-3 параметр language вообще принимает только en и multi.
      // Ставить на этом распознавание всей игры нельзя.
      params.set("detect_language", "true");
    } else {
      params.set("language", languageCode);
    }
    // keyterm по умолчанию выключен: у nova-3 он только для английского и
    // тарифицируется отдельно, а языков в игре будет несколько десятков.
    if ((Deno.env.get("ASR_KEYTERMS") ?? "0") === "1" && languageCode === "en") {
      for (const phrase of hintPhrases.slice(0, 50)) params.append("keyterm", phrase);
    }
    return params;
  };

  const startedAt = Date.now();
  const call = (params: URLSearchParams, budgetMs: number) =>
    fetchWithTimeout(`${baseUrl}/listen?${params.toString()}`, {
      method: "POST",
      headers: {
        Authorization: `Token ${apiKey}`,
        // Deepgram определяет формат по содержимому файла; WAV-заголовок,
        // который пишет клиент, он читает сам.
        "Content-Type": "audio/wav",
      },
      body: audio,
    }, budgetMs);

  let detect = detectionWanted;
  let res = await call(buildParams(detect), timeoutMs);
  let retriedWithoutDetection = false;
  let firstError = "";

  // Повторяем ТОЛЬКО на 400 — «мы прислали не те параметры». 401 (ключ),
  // 402 (деньги), 429 (лимит) и 5xx определением языка не лечатся: повтор
  // там сжёг бы вторую попытку впустую и, что хуже, спрятал настоящую
  // причину за успехом или за чужой ошибкой.
  if (!res.ok && detect && res.status === 400) {
    firstError = `${res.status}: ${(await res.text().catch(() => "")).slice(0, 300)}`;
    console.error("asr/deepgram: отверг запрос с определением языка,", firstError);
    detect = false;
    retriedWithoutDetection = true;
    const leftMs = timeoutMs - (Date.now() - startedAt);
    // Меньше трёх секунд на вторую попытку — уже не попытка, а гарантия
    // таймаута; в этом случае честнее вернуть исходную ошибку.
    if (leftMs >= 3_000) res = await call(buildParams(false), leftMs);
  }

  const meta = {
    provider: "deepgram",
    model,
    language: languageCode,
    detect_language: detect,
    retried_without_detection: retriedWithoutDetection,
    ...(firstError ? { detection_rejected_with: firstError } : {}),
    keyterms: (Deno.env.get("ASR_KEYTERMS") ?? "0") === "1" && languageCode === "en"
      ? hintPhrases.length
      : 0,
    audio_bytes: audio.byteLength,
  };

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    // Подсказка по коду ответа: без неё в отладочной панели видно «HTTP
    // 401» и непонятно, чинить ключ, права или запрос.
    const hint = res.status === 401 || res.status === 403
      ? " — ключ не принят: проверь ASR_API_KEY (npx supabase secrets set ASR_API_KEY=...)"
      : res.status === 400
      ? " — Deepgram не принял параметры запроса (модель/язык/их сочетание)"
      : res.status === 402
      ? " — на счёте Deepgram кончились средства"
      : res.status === 429
      ? " — превышен лимит запросов Deepgram"
      : "";
    return failed(`Deepgram HTTP ${res.status}${hint}: ${body.slice(0, 500)}`, {
      ...meta,
      elapsed_ms: Date.now() - startedAt,
    });
  }

  const data = await res.json();
  const base = {
    ...meta,
    elapsed_ms: Date.now() - startedAt,
    audio_seconds: typeof data?.metadata?.duration === "number"
      ? Math.round(data.metadata.duration * 10) / 10
      : null,
  };

  const channel = data?.results?.channels?.[0];
  const alternative = channel?.alternatives?.[0];

  // Ответа нужной формы нет вовсе — это поломка, а НЕ записанная тишина.
  // Разница принципиальная: за тишину игрок получает 1, за нашу поломку —
  // нейтральный балл. Тишину Deepgram возвращает иначе: канал на месте,
  // а transcript в нём пустая строка (случай ниже).
  if (typeof alternative?.transcript !== "string") {
    return failed("Deepgram ответил без results.channels[0].alternatives[0].transcript", base);
  }

  const transcript = alternative.transcript.trim();
  // Язык берём у провайдера. Не назвал (определение выключено или не
  // сработало) — оставляем null: тогда работает проверка по письменности,
  // а не наша догадка.
  const detectedLanguage = languageFromTag(channel?.detected_language);

  if (transcript.length === 0) return empty({ ...base, detected_language: detectedLanguage });

  const words: TranscribedWord[] = [];
  for (const w of alternative?.words ?? []) {
    // Deepgram отдаёт и word (как услышал), и punctuated_word (с
    // пунктуацией и регистром). Для списка неуверенных слов нужен первый:
    // судье показывают само слово, а не его оформление.
    const word = typeof w?.word === "string" ? w.word : null;
    if (word === null) continue;
    words.push({ word, confidence: typeof w?.confidence === "number" ? w.confidence : 0 });
  }

  const confidence = typeof alternative?.confidence === "number" ? alternative.confidence : 0;
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
