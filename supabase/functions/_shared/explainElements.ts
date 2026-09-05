/**
 * Объяснение ОШИБОК от языковой модели.
 *
 * Разделение труда здесь принципиальное и стоит его назвать прямо:
 *
 *   * ЧТО игрок сказал неверно — считает elementScoring.ts, без модели.
 *     Детерминированно, бесплатно, за микросекунды, и балл от настроения
 *     провайдера не зависит.
 *   * ПОЧЕМУ правильно именно так — объясняет модель, и только для тех
 *     элементов, которые игрок потерял. Он только что ошибся и, скорее
 *     всего, не понимает причины; это и есть момент, когда объяснение
 *     нужно.
 *
 * Модель ЗАМЕНИЛА собой пояснения из датасета (assets/cefr/explanations_*).
 * У готовых файлов было два неустранимых недостатка: они написаны про
 * РОДНУЮ формулировку (пояснение к «в семь», а не к «at seven») и ничего
 * не знают о том, что игрок сказал на самом деле. Модель объясняет ровно
 * ту форму, которую нужно было произнести, и может связать её с тем, что
 * игрок произнёс вместо неё. Файлы остаются запасным путём: если модель не
 * ответила, клиент показывает пояснение из датасета — оно хуже, но лучше
 * пустоты.
 *
 * ГРАНИЦА ОДНИМ ЭЛЕМЕНТОМ НЕ ОГРАНИЧЕНА. Форма одного куска часто
 * определяется другим («She works» — потому что подлежащее третьего лица;
 * порядок слов в вопросе — из-за вспомогательного глагола в начале), и
 * модели прямо разрешено ссылаться на соседние части фразы. Запрет на это
 * сделал бы половину объяснений неполными.
 */

import { extractJson, isProviderLimit } from "./evaluateGrammar.ts";

/** Одно объяснение: к какому элементу и что сказать игроку. */
export interface ElementExplanation {
  /** Номер элемента в эталонной фразе, с нуля. */
  index: number;
  text: string;
}

export interface ExplainResult {
  /** Номер элемента -> текст объяснения. */
  byIndex: Map<number, string>;
  /** Модель не ответила или ответила не тем — клиент откатится на датасет. */
  degraded: boolean;
  debug: Record<string, unknown>;
}

/**
 * Включён ли разбор ошибок моделью.
 *
 * ПО УМОЛЧАНИЮ ВКЛЮЧЁН — в отличие от JUDGE_ENABLED, который включает
 * модель ещё и на выставление балла. Это разные вещи: объяснение модель
 * пишет заметно лучше готового файла, а балл она выставляет субъективно и
 * медленно. Выключить объяснения (например, чтобы не тратить провайдера
 * на прогон тестов) — `npx supabase secrets set EXPLAIN_ENABLED=0`.
 */
export const EXPLAIN_ENABLED = (Deno.env.get("EXPLAIN_ENABLED") ?? "1") !== "0";

/**
 * Сколько ошибок объяснять максимум.
 *
 * Потерять можно и все двадцать элементов фразы C2 — и тогда игрок получит
 * простыню, которую не станет читать, а мы заплатим за неё провайдеру.
 * Пять — столько, сколько человек за раз способен разобрать.
 */
const MAX_EXPLAINED = Number(Deno.env.get("EXPLAIN_MAX_ELEMENTS") ?? 5);

const TIMEOUT_MS = Number(Deno.env.get("EXPLAIN_TIMEOUT_MS") ?? 60_000);

/** Меньше этого запускать запрос бессмысленно — он не успеет вернуться. */
const MIN_SLICE_MS = 6_000;

const SYSTEM_PROMPT =
  `Ты объясняешь учащемуся, ПОЧЕМУ правильная фраза звучит именно так.

Контекст: учащийся переводил фразу вслух и ошибся в некоторых её частях.
Тебе дают эталонный перевод, то, что он сказал на самом деле, и список
частей, которые он не произнёс или произнёс неверно.

ГЛАВНОЕ ТРЕБОВАНИЕ: после объяснения должно стать понятно, ПОЧЕМУ так, а
не просто КАК правильно. Учащийся только что ошибся и, скорее всего, не
понимает причины. «Нужно сказать "at seven"» — плохо. «Время на часах в
английском идёт с предлогом "at": "at seven", "at half past six". Предлог
"in" здесь не подходит — он для более длинных отрезков: "in the morning"»
— хорошо.

ПРАВИЛА:
1. Пиши на РОДНОМ языке учащегося (он указан в запросе). Весь текст
   объяснения — на нём.
2. Слова и обороты ЦЕЛЕВОГО языка приводи в двойных кавычках и ровно в том
   виде, в котором они стоят в эталоне: "at seven", "works".
3. Объяснение НЕ обязано ограничиваться одной частью фразы. Если форма
   этой части зависит от другой (согласование, время, порядок слов,
   вспомогательный глагол) — скажи об этом и назови ту часть тоже.
4. Если видно, что именно сказал учащийся вместо правильного варианта, —
   объясни, чем его вариант отличается по смыслу или почему он неверен.
5. Два-четыре предложения на одну часть. Без воды и без похвалы.
6. Не выдумывай ошибок за пределами присланного списка.

ФОРМАТ ОТВЕТА — строго JSON, без markdown-обёртки:
{"explanations":[{"index":<число из списка>,"text":"<объяснение>"}]}
Ровно один объект на каждую присланную часть, index — из запроса.`;

function buildUserPrompt(
  targetLanguage: string,
  nativeLanguage: string,
  expectedPhrase: string,
  transcript: string,
  missed: ElementExplanation[],
): string {
  return [
    `Целевой язык (на нём говорил учащийся): ${targetLanguage}`,
    `Родной язык учащегося (НА НЁМ пиши объяснения): ${nativeLanguage}`,
    "",
    "Эталонный перевод фразы целиком:",
    expectedPhrase,
    "",
    "Что учащийся сказал на самом деле:",
    transcript.length > 0 ? transcript : "(ничего не разобрано)",
    "",
    "Части фразы, которые он не произнёс или произнёс неверно:",
    ...missed.map((m) => `${m.index}: "${m.text}"`),
  ].join("\n");
}

/** Ответ модели -> список объяснений. null, если форма не та. */
function validate(value: unknown, allowed: Set<number>): ElementExplanation[] | null {
  if (typeof value !== "object" || value === null) return null;
  const raw = (value as Record<string, unknown>).explanations;
  if (!Array.isArray(raw)) return null;

  const out: ElementExplanation[] = [];
  for (const item of raw) {
    if (typeof item !== "object" || item === null) continue;
    const record = item as Record<string, unknown>;
    const index = typeof record.index === "number" ? record.index : Number(record.index);
    const text = record.text;
    if (!Number.isInteger(index) || typeof text !== "string") continue;
    // Модель иногда объясняет то, о чём её не просили. Такие объяснения
    // отбрасываем: они относились бы к элементу, который игрок сказал
    // верно, и подсветить их всё равно негде.
    if (!allowed.has(index)) continue;
    const trimmed = text.trim();
    if (trimmed.length === 0) continue;
    out.push({ index, text: trimmed });
  }
  return out.length > 0 ? out : null;
}

async function callOnce(
  targetLanguage: string,
  nativeLanguage: string,
  expectedPhrase: string,
  transcript: string,
  missed: ElementExplanation[],
  useResponseFormat: boolean,
  timeoutMs: number,
): Promise<string> {
  const baseUrl = Deno.env.get("LLM_BASE_URL") ?? "https://api.b.ai/v1";
  const apiKey = Deno.env.get("LLM_API_KEY");
  const model = Deno.env.get("LLM_MODEL");
  if (!apiKey) throw new Error("LLM_API_KEY is not configured");
  if (!model) throw new Error("LLM_MODEL is not configured");

  // Таймаут обязателен: без него зависший провайдер держит запрос до
  // убийства всей Edge Function платформой, а это происходит ДО
  // catch-блока — и задача осталась бы в 'processing' навсегда.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  let res: Response;
  try {
    res = await fetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          {
            role: "user",
            content: buildUserPrompt(
              targetLanguage,
              nativeLanguage,
              expectedPhrase,
              transcript,
              missed,
            ),
          },
        ],
        stream: false,
        ...(useResponseFormat ? { response_format: { type: "json_object" } } : {}),
        temperature: 0.3,
      }),
      signal: controller.signal,
    });
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") {
      throw new Error(`LLM request timed out after ${Math.round(timeoutMs / 1000)}s`);
    }
    throw e;
  } finally {
    clearTimeout(timeout);
  }

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`LLM HTTP ${res.status}: ${body.slice(0, 500)}`);
  }

  const data = await res.json();
  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== "string" || content.trim().length === 0) {
    throw new Error("LLM вернул пустой ответ");
  }
  return content;
}

/**
 * Объясняет непроизнесённые элементы.
 *
 * НИКОГДА НЕ БРОСАЕТ. Объяснение — приятное дополнение к раунду, а не его
 * суть: балл уже посчитан без модели, и уронить из-за неё запись
 * результата было бы обменом ценного на необязательное. Любой сбой даёт
 * degraded: true, и клиент показывает пояснение из датасета.
 */
export async function explainMissedElements(
  targetLanguage: string,
  nativeLanguage: string,
  /** Эталон БЕЗ разделителей «|» — модели они ни к чему. */
  expectedPhrase: string,
  transcript: string,
  missed: ElementExplanation[],
  /** Остаток бюджета задачи. Пережить его запрос не имеет права. */
  budgetMs: number,
): Promise<ExplainResult> {
  const empty = new Map<number, string>();

  if (!EXPLAIN_ENABLED) {
    return { byIndex: empty, degraded: false, debug: { status: "off", reason: "EXPLAIN_ENABLED=0" } };
  }
  if (missed.length === 0) {
    return { byIndex: empty, degraded: false, debug: { status: "skipped", reason: "ошибок нет" } };
  }

  const timeoutMs = Math.min(TIMEOUT_MS, budgetMs);
  if (timeoutMs < MIN_SLICE_MS) {
    return {
      byIndex: empty,
      degraded: true,
      debug: {
        status: "skipped",
        reason: `на разбор осталось ${Math.round(budgetMs / 1000)}с — меньше минимума`,
      },
    };
  }

  // Объясняем не всё подряд: см. MAX_EXPLAINED. Берём первые по порядку
  // фразы, а не случайные, — так объяснения читаются подряд с началом.
  const asked = missed.slice(0, MAX_EXPLAINED);
  const allowed = new Set(asked.map((m) => m.index));
  const startedAt = Date.now();

  // Две попытки, и вторая — БЕЗ response_format: часть провайдеров это
  // поле не знает и отвечает на него 400. Без такого отката разбор у
  // такого провайдера не работал бы вовсе, молча деградируя.
  let lastError = "";
  for (const useResponseFormat of [true, false]) {
    const left = timeoutMs - (Date.now() - startedAt);
    if (left < MIN_SLICE_MS) break;
    try {
      const content = await callOnce(
        targetLanguage,
        nativeLanguage,
        expectedPhrase,
        transcript,
        asked,
        useResponseFormat,
        left,
      );
      const parsed = validate(extractJson(content), allowed);
      if (parsed) {
        return {
          byIndex: new Map(parsed.map((p) => [p.index, p.text])),
          degraded: false,
          debug: {
            status: "ok",
            model: Deno.env.get("LLM_MODEL") ?? "(не задана)",
            asked: asked.length,
            answered: parsed.length,
            response_format: useResponseFormat,
            elapsed_ms: Date.now() - startedAt,
          },
        };
      }
      lastError = `ответ не той формы: ${content.slice(0, 200)}`;
    } catch (e) {
      lastError = e instanceof Error ? e.message : String(e);
      // Лимит провайдера повтором не лечится — вторая попытка сожгла бы
      // остаток бюджета впустую и спрятала настоящую причину.
      if (isProviderLimit(lastError)) break;
    }
  }

  console.error("explainMissedElements: разбор не получен", lastError);
  return {
    byIndex: empty,
    degraded: true,
    debug: {
      status: "degraded",
      reason: lastError,
      provider_limit: isProviderLimit(lastError),
      asked: asked.length,
      elapsed_ms: Date.now() - startedAt,
    },
  };
}
