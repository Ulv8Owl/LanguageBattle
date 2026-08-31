import { empty, failed, fetchWithTimeout, type TranscriptionResult } from "./types.ts";

/**
 * Whisper-совместимый /audio/transcriptions (OpenAI и все, кто повторяет
 * его формат) — запасной путь, если основной провайдер окажется
 * недоступен; можно указать тот же base_url, что у LLM-судьи.
 *
 * Пословной уверенности здесь нет — заполняем её нулями, поле в схеме
 * всё равно задел на будущее и в расчёте балла не участвует.
 */
export async function transcribeOpenAi(
  audio: Uint8Array,
  languageCode: string,
  _alternativeLanguages: string[],
  apiKey: string,
  _hintPhrases: string[],
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
