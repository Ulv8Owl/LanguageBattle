import { bcp47For, isKnownLanguage } from "./languages.ts";
import { empty, failed, fetchWithTimeout, type TranscribedWord, type TranscriptionResult } from "./types.ts";
import { languageFromTag } from "./languages.ts";
import { parseWav, toBase64 } from "./util.ts";

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
export async function transcribeGoogle(
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
    .filter((code) => code !== languageCode && isKnownLanguage(code))
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
        // Распознаватель НЕ ЗАПЕРТ в одном языке.
        //
        // Раньше сюда уходил только целевой язык, и это была не настройка
        // качества, а жёсткое ограничение: Google обязан выдать текст на
        // заданном языке и ничего другого выдать не может. Игрок,
        // прочитавший фразу задания вслух вместо перевода, получал не
        // «не тот язык», а набор целевых слов, похожих по звучанию на его
        // родные, — и судья разбирал эту бессмыслицу всерьёз.
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
    const resultLanguage = languageFromTag(result?.languageCode);
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
