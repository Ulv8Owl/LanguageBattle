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

import { bcp47For } from "../_shared/transcribeAudio.ts";

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
  const apiKey = Deno.env.get("ASR_API_KEY");
  if (!apiKey) {
    return {
      configured: false,
      reachable: null,
      detail: "ASR_API_KEY не задан — распознавание речи не заработает: " +
        "npx supabase secrets set ASR_API_KEY=<ключ>",
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
            model: Deno.env.get("ASR_MODEL") ?? "latest_short",
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
  const apiKey = Deno.env.get("LLM_API_KEY");
  if (!apiKey) {
    return {
      configured: false,
      reachable: null,
      detail: "LLM_API_KEY не задан — судья не заработает: " +
        "npx supabase secrets set LLM_API_KEY=<ключ>",
    };
  }

  const baseUrl = Deno.env.get("LLM_BASE_URL") ?? "https://api.b.ai/v1";
  const model = Deno.env.get("LLM_MODEL") ?? "DeepSeek-V4-Flash";
  try {
    const res = await withTimeout((signal) =>
      fetch(`${baseUrl}/chat/completions`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
        signal,
        body: JSON.stringify({
          model,
          messages: [{ role: "user", content: "ping" }],
          stream: false,
          max_tokens: 1,
        }),
      })
    );
    if (res.ok) {
      return {
        configured: true,
        reachable: true,
        detail: `${baseUrl} отвечает 200 на модель ${model}, ключ принят (${fingerprint(apiKey)})`,
      };
    }
    const body = await res.text().catch(() => "");
    return {
      configured: true,
      reachable: false,
      detail: `${baseUrl} вернул HTTP ${res.status}: ${body.slice(0, 300)}`,
    };
  } catch (e) {
    return { configured: true, reachable: false, detail: `запрос не удался: ${e}` };
  }
}

Deno.serve(async (req) => {
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const presented = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!serviceKey || presented !== serviceKey) {
    return new Response(JSON.stringify({ error: "service_role key required" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const [asr, llm] = await Promise.all([checkAsr(), checkLlm()]);
  const ready = asr.reachable !== false && llm.reachable !== false && asr.configured && llm.configured;

  return new Response(
    JSON.stringify(
      {
        ready,
        asr: { provider: Deno.env.get("ASR_PROVIDER") ?? "google", ...asr },
        llm: { base_url: Deno.env.get("LLM_BASE_URL") ?? "https://api.b.ai/v1", ...llm },
        hint: ready
          ? "Ключи на месте и принимаются провайдерами."
          : "Смотрите detail у того блока, где configured=false или reachable=false.",
      },
      null,
      2,
    ),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
