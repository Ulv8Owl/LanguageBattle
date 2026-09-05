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
 * КТО ПИШЕТ РАЗБОР ПЕРВЫМ. Датасет, а не модель. Пояснения лежат по парам
 * «родной-целевой» (assets/cefr/explanations/RU-EN/... и остальные пять) и
 * написаны для конкретной пары: на языке, которым игрок владеет, про язык,
 * который он учит. Они доступны мгновенно, ничего не стоят и не зависят от
 * лимитов провайдера. Раньше пояснения раскладывались по одному языку, и
 * тогда игроку с парой ru→en показывали разбор РУССКОЙ формулировки
 * («в семь» вместо "at seven") — вот это и было неустранимо, а не сама
 * идея заранее написанного текста.
 *
 * Модель подключается там, где датасет молчит: фраза не из банка (старый
 * раунд без разделителей), пара вне шести покрытых, элемент за пределами
 * таблицы. То есть она — не основной путь, а страховка, и в обычном раунде
 * к провайдеру не ходят вовсе.
 *
 * ГРАНИЦА ОДНИМ ЭЛЕМЕНТОМ НЕ ОГРАНИЧЕНА. Форма одного куска часто
 * определяется другим («She works» — потому что подлежащее третьего лица;
 * порядок слов в вопросе — из-за вспомогательного глагола в начале), и
 * модели прямо разрешено ссылаться на соседние части фразы. Запрет на это
 * сделал бы половину объяснений неполными.
 */

import { extractJson, isProviderLimit } from "./evaluateGrammar.ts";
import { llmChat, llmConfigDebug, llmKey, missingLlmKeyMessage } from "./llmChat.ts";

/** Одно объяснение: к какому элементу и что сказать игроку. */
export interface ElementExplanation {
  /** Номер элемента в эталонной фразе, с нуля. */
  index: number;
  text: string;
}

export interface ExplainResult {
  /** Номер элемента -> текст объяснения. */
  byIndex: Map<number, string>;
  /** Модель не ответила или ответила не тем. Балл от этого не зависит. */
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
 * Языковые пары, для которых разбор уже написан в датасете.
 *
 * Список приходится держать здесь копией: сам датасет — это мегабайт
 * текста в репозитории приложения, и класть его в Edge Function только
 * ради проверки «покрыта ли пара» значило бы возить мегабайт на каждый
 * холодный старт. Клиент читает те же файлы напрямую и подставляет текст
 * сам; серверу достаточно знать, что спрашивать модель не нужно.
 *
 * Расширяя датасет новой парой, добавь её и сюда — иначе провайдера будут
 * дёргать зря. Забыть наоборот (добавить сюда без файлов) хуже: тогда
 * разбора не будет ни от кого, и игрок увидит честное «разбора нет».
 */
const DATASET_PAIRS = new Set([
  "en-ru", "en-es", "ru-en", "ru-es", "es-en", "es-ru",
]);

/**
 * Спрашивать ли модель, когда пару покрывает датасет.
 *
 * По умолчанию НЕТ: готовый разбор для этой пары уже написан, клиент
 * подставит его сам, и вызов провайдера был бы платой за текст, который и
 * так есть. Включить модель поверх датасета (например, чтобы сравнить
 * качество) — `npx supabase secrets set EXPLAIN_PREFER_DATASET=0`.
 */
const PREFER_DATASET = (Deno.env.get("EXPLAIN_PREFER_DATASET") ?? "1") !== "0";

/** Есть ли в датасете готовые разборы для этой пары. */
export function hasDatasetExplanations(nativeLanguage: string, targetLanguage: string): boolean {
  return DATASET_PAIRS.has(`${nativeLanguage.toLowerCase()}-${targetLanguage.toLowerCase()}`);
}

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
  const apiKey = llmKey();
  if (!apiKey) throw new Error(missingLlmKeyMessage());

  return await llmChat(apiKey, {
    system: SYSTEM_PROMPT,
    user: buildUserPrompt(targetLanguage, nativeLanguage, expectedPhrase, transcript, missed),
    json: useResponseFormat,
    temperature: 0.3,
    timeoutMs,
  });
}

/**
 * Объясняет непроизнесённые элементы.
 *
 * НИКОГДА НЕ БРОСАЕТ. Объяснение — приятное дополнение к раунду, а не его
 * суть: балл уже посчитан без модели, и уронить из-за неё запись
 * результата было бы обменом ценного на необязательное. Любой сбой даёт
 * degraded: true и пустой текст, а клиент честно говорит, что разбора нет.
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
  // Пару покрывает датасет — к провайдеру не идём вовсе. degraded здесь
  // false: разбор у игрока будет, просто не от модели.
  if (PREFER_DATASET && hasDatasetExplanations(nativeLanguage, targetLanguage)) {
    return {
      byIndex: empty,
      degraded: false,
      debug: {
        status: "dataset",
        reason: `пара ${nativeLanguage}-${targetLanguage} покрыта датасетом, модель не нужна`,
        asked: 0,
      },
    };
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
            ...llmConfigDebug(),
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
