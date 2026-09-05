// Единая точка входа в распознавание речи. Всё, что снаружи (evaluate-
// recording) должно знать про ASR — этот файл; конкретные провайдеры
// (google.ts, deepgram.ts, openai.ts) реализуют один и тот же интерфейс
// (AsrProvider в types.ts) и сюда не знают друг о друге.
//
// ПОЧЕМУ ASR переехал на сервер (историческая причина, не про сегодняшний
// рефакторинг). Клиент писал аудио пакетом record и ОДНОВРЕМЕННО слушал
// микрофон системным распознавателем через speech_to_text. На Android так
// нельзя: AudioRecord (record) и SpeechRecognizer (speech_to_text)
// конкурируют за один и тот же вход, и тот, кто пришёл вторым, не получает
// звук вообще. Транскрипт всегда оказывался пустым, из-за чего
// evaluate-recording уходил в ветку "пустой транскрипт" и НИ РАЗУ не
// доходил до LLM — игрок видел балл 1 и "ошибок не найдено" что бы он ни
// сказал. Теперь клиент только пишет файл, а речь распознаётся здесь, по
// загруженному аудио.
//
// Смена провайдера — это правка переменных окружения Edge Function, а не
// кода:
//   ASR_PROVIDER    google (по умолчанию) | deepgram | openai
//   ASR_API_KEY     ключ провайдера
//   ASR_BASE_URL    переопределение эндпоинта (обычно не нужно)
//   ASR_MODEL       google: latest_long; deepgram: nova-3; openai: whisper-1
//   ASR_KEYTERMS    deepgram only. 1 — подсказывать фразу раунда (keyterm).
//                   По умолчанию 0: у nova-3 это только английский и платно
//   ASR_TIMEOUT_MS  таймаут запроса, по умолчанию 60000
//
// ЯЗЫК ЗАДАЁТСЯ ЖЁСТКО. Переменной для определения языка здесь больше нет:
// провайдер обязан распознавать РОВНО тот язык, на который игрок сейчас
// переводит. Определение языка стоило качества (распознаватель, выбирающий
// язык, хуже слышит акцент) и приводило к ложным обвинениям «ответил не на
// том языке» — см. раздел про это в supabase/README.md.
//
// deepgram полностью реализован и проверен (см. историю ветки deepgram),
// но НЕ АКТИВЕН по умолчанию — включается явной ASR_PROVIDER=deepgram, не
// затрагивая ничего в остальном коде. openai — любой эндпоинт с
// whisper-совместимым /audio/transcriptions (в том числе тот же base_url,
// что у LLM-судьи), запасной путь, если основной провайдер недоступен.

import { googleKey, missingKeyMessage } from "../googleKey.ts";
import type { AsrProvider, TranscriptionResult } from "./types.ts";
import { failed } from "./types.ts";
import { transcribeGoogle } from "./google.ts";
import { transcribeDeepgram } from "./deepgram.ts";
import { transcribeOpenAi } from "./openai.ts";

export type { TranscribedWord, TranscriptionResult } from "./types.ts";
export { definitelyNotLanguage, bcp47For, languageFromTag } from "./languages.ts";

const PROVIDERS: Record<string, AsrProvider> = {
  google: transcribeGoogle,
  deepgram: transcribeDeepgram,
  openai: transcribeOpenAi,
};

/**
 * Таймаут запроса к ASR. Он НЕ ограничивает длину записи — только не даёт
 * зависшему провайдеру утащить за собой всю задачу: без таймаута функцию
 * убивает платформа ДО блока catch, и задача остаётся в 'processing'
 * навсегда. Поэтому он щедрый и настраивается.
 */
const ASR_TIMEOUT_MS = Number(Deno.env.get("ASR_TIMEOUT_MS") ?? 60_000);

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
   * неносителя; см. speechContexts в google.ts.
   */
  hintPhrases: string[] = [],
  /**
   * Сколько времени осталось у воркера на распознавание. Собственный
   * ASR_TIMEOUT_MS остаётся верхней границей, но пережить бюджет задачи он
   * не может: воркера убивают снаружи, и тогда результат не запишет никто.
   */
  budgetMs: number = ASR_TIMEOUT_MS,
): Promise<TranscriptionResult> {
  const provider = (Deno.env.get("ASR_PROVIDER") ?? "google").toLowerCase();
  // Ключ берётся общий, если своего нет: у Google все три сервиса
  // (распознавание, синтез, модель) могут ходить под одним ключом, и
  // держать три копии одного значения — это три места, где однажды
  // обновят два. Свой ASR_API_KEY по-прежнему главнее: он нужен, когда
  // провайдер не Google вовсе.
  const apiKey = googleKey("asr");
  if (!apiKey) return failed(missingKeyMessage("asr"));
  if (audio.byteLength === 0) return failed("audio file is empty");
  const timeoutMs = Math.max(3_000, Math.min(ASR_TIMEOUT_MS, budgetMs));

  const impl = PROVIDERS[provider];
  if (!impl) {
    const known = Object.keys(PROVIDERS).join(", ");
    return failed(`unknown ASR_PROVIDER "${provider}" (expected one of: ${known})`);
  }

  try {
    return await impl(audio, languageCode, apiKey, hintPhrases, timeoutMs);
  } catch (e) {
    return failed(`provider ${provider} threw: ${e}`);
  }
}
