// Единый интерфейс ASR-провайдера. Причина, по которой он выделен в
// отдельный файл: провайдеров у нас уже три (google/deepgram/openai), и
// когда-нибудь появится четвёртый — этот файл описывает контракт, которому
// обязан следовать любой новый файл в этой папке, а index.ts просто решает,
// какой из них позвать.

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
   * приложения или null, если провайдер не сказал.
   *
   * Это не наша догадка, а поле ответа самого провайдера (у Google —
   * `results[].languageCode`, у Deepgram — `channels[].detected_language`),
   * которое появляется, когда его попросили определить язык. Своего
   * определителя языка в проекте нет и не будет.
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

/**
 * Сигнатура, которой должна соответствовать функция-провайдер в этой папке
 * (transcribeGoogle, transcribeDeepgram, transcribeOpenAi, …), чтобы
 * index.ts мог вызывать любую из них одинаково.
 */
export type AsrProvider = (
  audio: Uint8Array,
  languageCode: string,
  /** Родной язык игрока (и другие возможные) — не все провайдеры его используют. */
  alternativeLanguages: string[],
  apiKey: string,
  hintPhrases: string[],
  timeoutMs: number,
) => Promise<TranscriptionResult>;

export function empty(debug: Record<string, unknown>): TranscriptionResult {
  return {
    transcript: "",
    confidence: 0,
    words: [],
    detectedLanguage: null,
    degraded: false,
    debug: { ...debug, status: "empty" },
  };
}

export function failed(reason: string, debug: Record<string, unknown> = {}): TranscriptionResult {
  console.error("asr:", reason);
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
 * Обёртка над fetch с таймаутом. Таймаут НЕ ограничивает длину записи —
 * только не даёт зависшему провайдеру утащить за собой всю задачу: без
 * него функцию убивает платформа ДО блока catch, и задача остаётся в
 * 'processing' навсегда.
 */
export async function fetchWithTimeout(
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
