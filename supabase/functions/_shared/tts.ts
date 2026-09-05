/**
 * Синтез речи — Google Cloud Text-to-Speech v1, text:synthesize.
 *
 * ЗАЧЕМ. В разборе игрок видит, как фраза должна выглядеть. Услышать, как
 * она должна ЗВУЧАТЬ, до сих пор было негде — а для языка это половина
 * дела: письменная правка не показывает ни ударения, ни связок, ни того,
 * что «должен был сказать» звучит совсем не так, как читается.
 *
 * ЯЗЫК ЗАДАЁТСЯ ПАРОЙ ИГРОКА, а не текстом. Определять язык по самому
 * тексту нельзя: исправленная фраза короткая, и на коротком тексте
 * определение ошибается — а ошибка здесь звучит как насмешка (английская
 * фраза, прочитанная по-русски). Поэтому язык приходит снаружи и там же
 * сверяется с активной парой.
 */

import { bcp47For, isKnownLanguage } from "./asr/languages.ts";
import { googleKey, missingKeyMessage } from "./googleKey.ts";

export interface SynthesisResult {
  /** MP3 в base64 — в таком виде он и уезжает клиенту. */
  audioContent: string;
  debug: Record<string, unknown>;
}

export class SynthesisError extends Error {
  readonly status: number;
  constructor(message: string, status = 502) {
    super(message);
    this.status = status;
  }
}

/**
 * Потолок длины. Фраза раунда — до семи предложений, это сотни символов;
 * тысяча оставляет запас и при этом не даёт превратить озвучку в
 * бесплатный синтезатор книг за наш счёт.
 */
export const MAX_TTS_CHARS = 1000;

const DEFAULT_BASE = "https://texttospeech.googleapis.com/v1";

export async function synthesizeSpeech(
  text: string,
  languageCode: string,
  timeoutMs = 15_000,
): Promise<SynthesisResult> {
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    throw new SynthesisError("нечего озвучивать: пустой текст", 400);
  }
  if (trimmed.length > MAX_TTS_CHARS) {
    throw new SynthesisError(
      `текст длиннее ${MAX_TTS_CHARS} символов (${trimmed.length})`,
      400,
    );
  }
  if (!isKnownLanguage(languageCode)) {
    throw new SynthesisError(`неизвестный язык "${languageCode}"`, 400);
  }

  const apiKey = googleKey("tts");
  if (!apiKey) throw new SynthesisError(missingKeyMessage("tts"), 503);

  const baseUrl = Deno.env.get("TTS_BASE_URL") ?? DEFAULT_BASE;
  const bcp47 = bcp47For(languageCode);
  // Голос НЕ ЗАКРЕПЛЁН по имени. Имена голосов у Google живут своей
  // жизнью: их добавляют, переименовывают и снимают с поддержки, а нам
  // нужны 32 языка. Запросив только язык, мы получаем голос, который
  // Google для этого языка считает основным, и не ломаемся при смене
  // каталога.
  const gender = Deno.env.get("TTS_VOICE_GENDER") ?? "FEMALE";
  // Чуть медленнее обычного — это образец произношения, а не диктор
  // новостей: игрок слушает, чтобы повторить.
  const speakingRate = Number(Deno.env.get("TTS_SPEAKING_RATE") ?? 0.95);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = Date.now();

  let res: Response;
  try {
    res = await fetch(`${baseUrl}/text:synthesize`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-goog-api-key": apiKey,
      },
      body: JSON.stringify({
        input: { text: trimmed },
        voice: { languageCode: bcp47, ssmlGender: gender },
        // MP3, а не LINEAR16: клиент его проигрывает как есть, и весит он
        // в разы меньше — а платим мы за трафик игрока.
        audioConfig: { audioEncoding: "MP3", speakingRate },
      }),
      signal: controller.signal,
    });
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") {
      throw new SynthesisError(`синтез не уложился в ${Math.round(timeoutMs / 1000)}с`, 504);
    }
    throw new SynthesisError(`синтез не удался: ${e}`);
  } finally {
    clearTimeout(timeout);
  }

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new SynthesisError(`Google TTS HTTP ${res.status}: ${body.slice(0, 300)}`);
  }

  const data = await res.json();
  const audioContent = data?.audioContent;
  if (typeof audioContent !== "string" || audioContent.length === 0) {
    throw new SynthesisError("Google TTS вернул пустой ответ");
  }

  return {
    audioContent,
    debug: {
      language: bcp47,
      gender,
      speaking_rate: speakingRate,
      chars: trimmed.length,
      elapsed_ms: Date.now() - startedAt,
    },
  };
}
