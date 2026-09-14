/**
 * Разбирает запись игрока на слова со временем и переводом.
 *
 * ЧТО СЮДА ПРИХОДИТ. Ссылка на запись, которую игрок только что залил из
 * памяти телефона, и язык, на который переводить. Запись живёт в хранилище
 * ровно столько, сколько идёт разбор: удаляет её клиент сразу после
 * ответа, а результат кладёт себе на устройство. Ни звука, ни расшифровки
 * мы у себя не держим — это файл игрока, разобранный по его же просьбе.
 *
 * ПОЧЕМУ ОДНА МОДЕЛЬ, А НЕ РАСПОЗНАВАНИЕ ПЛЮС ПЕРЕВОД. Пословный перевод
 * обязан лечь ровно на пословную расшифровку. Разложив их по двум вызовам,
 * мы получаем два независимых разбиения на слова: одно склеит артикль со
 * словом, другое нет — и дальше перевод едет относительно оригинала до
 * конца записи, причём молча. Одна модель выдаёт пару в одном объекте, и
 * разъехаться там нечему.
 *
 * ЭНЕРГИЯ СПИСЫВАЕТСЯ ЗДЕСЬ, А НЕ НА КЛИЕНТЕ: списание клиентом — это
 * предложение не списывать.
 */

import { createClient } from "jsr:@supabase/supabase-js@2";
import { audioUrlFor } from "../_shared/audioLink.ts";
import { judgeBaseUrl, judgeKey } from "../_shared/review.ts";

/** Модель. Та же, что уже разбирает записи в бою. */
const MODEL = Deno.env.get("OMNI_TRANSCRIBE_MODEL") ?? "qwen3-omni-flash";

/** Длиннее этого не беремся: ответ не успеет вернуться. */
const MAX_DURATION_MS = 12 * 60 * 1000;

const TIMEOUT_MS = Number(Deno.env.get("OMNI_TIMEOUT_MS") ?? "180000");

/**
 * Цена разбора: одна единица за каждые начатые полминуты.
 *
 * ТА ЖЕ ФОРМУЛА ПОВТОРЕНА НА КЛИЕНТЕ (lib/data/library_track.dart).
 * Дублирование вынужденное: там её показывают ДО подтверждения, здесь
 * списывают. Разойдясь, они покажут одну цену, а возьмут другую.
 */
function energyCost(durationMs: number): number {
  if (!Number.isFinite(durationMs) || durationMs <= 0) return 1;
  return Math.max(1, Math.ceil(durationMs / 30_000));
}

const LANGUAGE_NAMES: Record<string, string> = {
  en: "English",
  ru: "Russian",
  es: "Spanish",
  pl: "Polish",
  de: "German",
  fr: "French",
  it: "Italian",
  pt: "Portuguese",
  tr: "Turkish",
  uk: "Ukrainian",
};

function languageName(code: string): string {
  return LANGUAGE_NAMES[code] ?? code;
}

function prompt(translateTo: string): string {
  const target = languageName(translateTo);
  return [
    "Transcribe this audio and translate it, WORD BY WORD.",
    "",
    "Answer with JSON only — no prose, no markdown fence:",
    '{"language":"<ISO code of the audio>","lines":[[{"w":"","t":"","start":0,"end":0}]]}',
    "",
    "Rules:",
    `1. "w" is ONE word exactly as sung or spoken, in the original language.`,
    `2. "t" is that single word translated into ${target}. Translate the word`,
    "   as it is used in this line, not its dictionary entry. If the word has",
    "   no separate translation (an article, an auxiliary), use an empty string.",
    '3. "start" and "end" are milliseconds from the beginning of the audio.',
    "   They must increase and must not overlap between words.",
    "4. Split into lines the way they are actually sung or said — a line is",
    "   one breath or one phrase, not a fixed number of words.",
    "5. Never merge two words into one object and never split one word in two:",
    "   the pair w/t must stay aligned for the whole recording.",
    "6. Transcribe only what is audible. Do not invent words to fill silence.",
  ].join("\n");
}

/** Достаёт JSON из ответа, даже если модель обернула его в ```json. */
function extractJson(raw: string): unknown | null {
  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/);
  const text = (fenced ? fenced[1] : raw).trim();
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(text.slice(start, end + 1));
  } catch {
    return null;
  }
}

/** Текст ответа native-режима DashScope. */
function nativeText(body: string): string | null {
  try {
    const parsed = JSON.parse(body);
    const output = parsed?.output;
    const direct = output?.text;
    if (typeof direct === "string" && direct.length > 0) return direct;
    const choice = output?.choices?.[0]?.message?.content;
    if (typeof choice === "string" && choice.length > 0) return choice;
    if (Array.isArray(choice)) {
      const joined = choice
        .map((part: Record<string, unknown>) => part?.text ?? "")
        .filter((t: unknown) => typeof t === "string" && t.length > 0)
        .join("");
      if (joined.length > 0) return joined;
    }
  } catch {
    return null;
  }
  return null;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  if (serviceKey.length === 0 || url.length === 0) {
    return json({ error: "функция не настроена" }, 500);
  }

  // Кто просит. Без этого списывать энергию не с кого.
  const authorization = req.headers.get("Authorization") ?? "";
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: auth } = await asUser.auth.getUser();
  const userId = auth?.user?.id;
  if (!userId) return json({ error: "не авторизован" }, 401);

  let body: { storagePath?: string; durationMs?: number; translateTo?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "не разобрал запрос" }, 400);
  }

  const storagePath = (body.storagePath ?? "").trim();
  const durationMs = Number(body.durationMs ?? 0);
  const translateTo = (body.translateTo ?? "").trim();
  if (storagePath.length === 0) return json({ error: "нет записи" }, 400);
  // ЧУЖУЮ ЗАПИСЬ РАЗОБРАТЬ НЕЛЬЗЯ. Путь приходит от клиента, и без этой
  // проверки любой, знающий чужой путь, оплатил бы своей энергией разбор
  // чужого файла — и получил бы его расшифровку.
  if (!storagePath.startsWith(`tracks/${userId}/`)) {
    return json({ error: "чужая запись" }, 403);
  }
  if (translateTo.length === 0) return json({ error: "не указан язык перевода" }, 400);
  if (durationMs > MAX_DURATION_MS) {
    return json({ error: "запись длиннее 12 минут — разбор не успеет" }, 400);
  }

  const key = judgeKey();
  if (!key) {
    return json(
      { error: "нет ключа модели: npx supabase secrets set OMNI_API_KEY=<ключ qwencloud>" },
      500,
    );
  }

  // ЭНЕРГИЯ СПИСЫВАЕТСЯ ДО ВЫЗОВА. Модель берёт деньги за попытку, а не за
  // удачу: списав после, мы дарили бы каждый неудачный разбор.
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const cost = energyCost(durationMs);
  const { data: left, error: spendError } = await admin.rpc("spend_energy", {
    p_user_id: userId,
    p_amount: cost,
    p_reason: "transcribe-track",
  });
  if (spendError) return json({ error: `не удалось списать энергию: ${spendError.message}` }, 500);

  // Ссылка кончается расширением файла — иначе провайдер не определит
  // формат (см. _shared/audioLink.ts и функцию asr-audio).
  let audioUrl: string;
  try {
    audioUrl = await audioUrlFor(storagePath, url, serviceKey);
  } catch (e) {
    return json({ error: `не собралась ссылка на запись: ${e}`, energy_left: left }, 500);
  }

  const host = judgeBaseUrl().replace(/\/compatible-mode\/v1\/?$/, "");
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(
      `${host}/api/v1/services/aigc/multimodal-generation/generation`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${key}`,
          "X-DashScope-SSE": "disable",
        },
        body: JSON.stringify({
          model: MODEL,
          input: {
            messages: [
              {
                role: "user",
                content: [
                  { type: "input_audio", input_audio: { data: audioUrl } },
                  { type: "text", text: prompt(translateTo) },
                ],
              },
            ],
          },
        }),
        signal: controller.signal,
      },
    );
    const raw = await res.text();
    if (!res.ok) {
      return json({ error: `модель ответила ${res.status}: ${raw.slice(0, 300)}`, energy_left: left }, 502);
    }

    const text = nativeText(raw);
    if (text === null) {
      return json({ error: "ответ без текста", energy_left: left }, 502);
    }
    const parsed = extractJson(text) as
      | { language?: string; lines?: unknown[] }
      | null;
    if (!parsed || !Array.isArray(parsed.lines) || parsed.lines.length === 0) {
      return json(
        { error: "модель вернула не разбор", sample: text.slice(0, 300), energy_left: left },
        502,
      );
    }

    return json({
      language: typeof parsed.language === "string" ? parsed.language : "",
      translation: translateTo,
      lines: parsed.lines,
      energy_spent: cost,
      energy_left: left,
    });
  } catch (e) {
    const reason = e instanceof Error && e.name === "AbortError"
      ? "разбор не уложился в срок"
      : `сбой вызова: ${e}`;
    return json({ error: reason, energy_left: left }, 504);
  } finally {
    clearTimeout(timer);
  }
});
