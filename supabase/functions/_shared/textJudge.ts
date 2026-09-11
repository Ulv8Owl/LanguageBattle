/**
 * Двухшаговый разбор: распознавание, потом текстовая модель.
 *
 * ЭТО АРХИТЕКТУРА ДО OMNI, ВОССТАНОВЛЕННАЯ РАДИ СРАВНЕНИЯ ЦЕНЫ. Шаг первый
 * — распознаватель превращает речь в текст (asr.ts). Шаг второй — обычная
 * текстовая модель судит этот текст. За аудио платит только первый, и он
 * заметно дешевле мультимодального разбора; второй получает символы.
 *
 * ЧТО ОСТАЛОСЬ ОБЩИМ С ВЕТКОЙ OMNI, И ЭТО ВАЖНЕЕ РАЗЛИЧИЙ. Лента разбора,
 * формула балла, отсев придирок, формат ответа для приложения — всё из
 * review.ts, слово в слово то же. Иначе сравнение двух архитектур измеряло
 * бы не модели, а разницу в нашей собственной арифметике.
 *
 * ЧЕМ ЗА ЭТО ПЛАТИМ. Судья не слышит записи. Произношение, ударение,
 * проглоченное окончание, оборванное слово — всё это до него не доезжает, а
 * распознаватель вдобавок приглаживает речь: расставляет знаки препинания,
 * пишет заглавные буквы, иногда правит грамматику. Промпт судьи прямо
 * запрещает считать ошибкой то, что могло прийти от распознавателя, — но
 * запретить можно только наказывать, а вернуть потерянное нельзя.
 */

import {
  attachMeanings,
  correctText,
  type JudgeResult,
  judgeBaseUrl,
  judgeKey,
  languageEndonym,
  languageName,
  parseJson,
  requestQwen,
  ribbon,
  sameLanguage,
} from "./review.ts";
import { diffWords } from "./textDiff.ts";
import { judgeTextPrompt } from "./prompts/judgeText.ts";
import { asrModel, transcribe } from "./asr.ts";

/**
 * Текстовые модели-судьи, между которыми можно переключаться из настроек.
 *
 * ПЕРВАЯ В СПИСКЕ РАБОТАЕТ ПО УМОЛЧАНИЮ, и порядок здесь не алфавитный.
 * Обычные чат-модели идут первыми, `qwen-mt-*` — последними, и вот почему:
 * `qwen-mt-*` это ПЕРЕВОДЧИКИ, а не собеседники. Они заточены выдавать
 * перевод входного текста, и свободный ответ по инструкции — тем более
 * JSON — им может быть не по профилю. Пока такая модель стояла первой,
 * ветка из коробки выглядела сломанной, хотя дело было только в выборе по
 * умолчанию.
 *
 * Из списка они не убраны: смысл ветки в том и есть, чтобы померить их на
 * живых записях. Модель, не вернувшая JSON, честно превращается в «модель
 * не ответила» и балл игроку не портит (см. degraded ниже).
 */
export const LLM_MODELS = [
  // Обычные чат-модели — им и адресован промпт с ответом в JSON.
  "qwen3.7-flash",
  "qwen-flash",
  "qwen3-vl-flash",
  "qwen-turbo",
  "qwen3.5-flash",
  "qwen2.5-omni-7b",
  "qwen3.8-flash",
  "qwen3-vl-plus",
  "qwen3.6-flash",
  "qwen3.5-27b",
  "qwen3.5-plus",
  "qwen-plus",
  "qwen3.6-plus",
  "qwen3.6-27b",
  // Переводчики. Стоят в конце намеренно — см. предупреждение выше.
  "qwen-mt-flash",
  "kimi-k3",
  "deepseek-v4-pro-0813",
  "glm-5.2",
  "qwen-mt-lite",
  "qwen-mt-turbo",
  "qwen-mt-plus",
] as const;

export const DEFAULT_LLM_MODEL = LLM_MODELS[0];

/** Выбор игрока сильнее окружения; незнакомое значение — модель по умолчанию. */
export function llmModel(chosen?: string | null): string {
  const wanted = (chosen ?? "").trim();
  if ((LLM_MODELS as readonly string[]).includes(wanted)) return wanted;
  const fromEnv = Deno.env.get("LLM_MODEL");
  if (fromEnv && (LLM_MODELS as readonly string[]).includes(fromEnv)) return fromEnv;
  return DEFAULT_LLM_MODEL;
}

export interface TextJudgeRequest {
  /**
   * Подписанная ссылка на запись — нужна двум формам вызова распознавания
   * из трёх (см. лесенку в asr.ts). Пусто — остаётся только вложение.
   */
  audioUrl?: string | null;
  audio: Uint8Array;
  /** Контейнер записи: wav, mp3, m4a — как есть у нас в хранилище. */
  audioFormat: string;
  nativeLanguage: string;
  targetLanguage: string;
  /** Задание на РОДНОМ языке — то, что видел игрок. */
  prompt: string;
  /** Наш перевод задания — ПРИБЛИЗИТЕЛЬНЫЙ ориентир. Пусто — блока нет. */
  reference: string;
  level: string;
  /** Остаток бюджета задачи на ОБА вызова. */
  budgetMs: number;
  /** Модель распознавания, выбранная игроком. Пусто — по умолчанию. */
  asrModelChoice?: string | null;
  /** Текстовая модель-судья, выбранная игроком. Пусто — по умолчанию. */
  llmModelChoice?: string | null;
}

/**
 * Оба шага целиком: звук на вход, разбор на выход. НИКОГДА НЕ БРОСАЕТ.
 *
 * Сбой любого из двух шагов — это degraded, а не падение воркера: задача
 * должна закрыться честным «модель не ответила», иначе она повиснет в
 * 'processing', а игрок будет ждать результат, которого не будет.
 */
export async function textJudge(req: TextJudgeRequest): Promise<JudgeResult> {
  const started = Date.now();
  const config = {
    provider: "asr+llm",
    asr_model: asrModel(req.asrModelChoice),
    llm_model: llmModel(req.llmModelChoice),
    base_url: judgeBaseUrl(),
    key_set: judgeKey() !== null,
  };
  const fail = (reason: string, extra: Record<string, unknown> = {}): JudgeResult => ({
    review: [],
    errors: [],
    audible: false,
    degraded: true,
    failureReason: reason,
    debug: { ...config, status: "failed", reason, ms: Date.now() - started, ...extra },
  });

  // --- Шаг первый: речь в текст --------------------------------------------
  const asr = await transcribe({
    audioUrl: req.audioUrl,
    audio: req.audio,
    audioFormat: req.audioFormat,
    model: req.asrModelChoice,
    budgetMs: req.budgetMs,
  });
  if (asr.error) return fail(`распознавание: ${asr.error}`, { asr: asr.debug });

  // Распознаватель послушал и речи не нашёл. Это ОТВЕТ, а не сбой: разбирать
  // нечего, и балл за такую запись минимальный, а не нейтральный.
  if (asr.text.length === 0) {
    return {
      review: [],
      errors: [],
      audible: false,
      degraded: false,
      silent: true,
      debug: {
        ...config,
        status: "silent",
        reason: "распознаватель не нашёл речи в записи",
        ms: Date.now() - started,
        asr: asr.debug,
      },
    };
  }

  // --- Шаг второй: текст судье ---------------------------------------------
  const spent = Date.now() - started;
  const system = judgeTextPrompt({
    native: languageName(req.nativeLanguage),
    nativeSelf: languageEndonym(req.nativeLanguage),
    target: languageName(req.targetLanguage),
    level: req.level,
    prompt: req.prompt,
    heard: asr.text,
    reference: req.reference.trim(),
  });
  // Задание и расшифровка уже стоят в системной части — тут остаётся только
  // просьба ответить. Дублировать их вторым сообщением значило бы дать
  // модели два слегка разных описания одной задачи.
  const answer = await requestQwen(
    system,
    [{ type: "text", text: "Answer with the JSON object described above." }],
    Math.max(0, req.budgetMs - spent),
    llmModel(req.llmModelChoice),
  );
  if ("error" in answer) {
    return fail(`судья ${llmModel(req.llmModelChoice)}: ${answer.error}`, { asr: asr.debug });
  }

  const raw = answer.raw;
  if (raw.trim().length === 0) return fail("судья вернул пустой ответ", { asr: asr.debug });

  const parsed = parseJson(raw);
  if (!parsed) {
    return fail(`ответ судьи не разобран как JSON: ${raw.slice(0, 300)}`, { asr: asr.debug });
  }

  // Игрок говорил не на том языке — это видно уже по расшифровке, и судья
  // это называет. Разбирать чужую речь как перевод нечем.
  const spoke = typeof parsed.spoke === "string" ? parsed.spoke.trim() : "";
  if (spoke.length > 0 && !sameLanguage(spoke, req.targetLanguage)) {
    return {
      review: [],
      errors: [],
      audible: true,
      degraded: false,
      wrongLanguage: true,
      spokenLanguage: spoke,
      debug: {
        ...config,
        status: "wrong_language",
        reason: `судья увидел ${spoke}, ожидался ${languageName(req.targetLanguage)}`,
        ms: Date.now() - started,
        asr: asr.debug,
        heard: asr.text,
        raw: raw.slice(0, 400),
      },
    };
  }

  const correct = typeof parsed.correct === "string" ? parsed.correct.trim() : "";
  if (correct.length === 0) {
    return fail(`в ответе судьи нет перевода: ${raw.slice(0, 300)}`, { asr: asr.debug });
  }

  // ЛЕНТУ СЧИТАЕМ МЫ, а не модель, — ровно как на ветке Omni. Сравнить две
  // строки по словам это арифметика, и арифметику надо считать, а не
  // спрашивать. Здесь сравнивается расшифровка против перевода судьи.
  // ЛЕНТУ СЧИТАЕМ МЫ, а не модель, — сравнить две строки по словам это
  // арифметика, и её надо считать, а не спрашивать. Переводы, которые
  // модель прислала списком, привязываются к готовым кускам по словам.
  const review = attachMeanings(ribbon(diffWords(asr.text, correct)), parsed.missing);

  const missed = review.filter((s) => s.kind === "miss");
  return {
    review,
    // СПИСКА ОШИБОК НА ЭТОЙ ВЕТКЕ НЕТ. Плашка — это сам красный текст в
    // ленте, а нажатие показывает перевод. Балл поэтому считается только по
    // доле несказанного: неверное слово всё равно попадает в неё, потому
    // что верное на его месте игрок не произнёс.
    errors: [],
    audible: true,
    degraded: false,
    debug: {
      ...config,
      status: "ok",
      ms: Date.now() - started,
      asr: asr.debug,
      heard: asr.text,
      correct,
      spans: {
        ok: review.filter((s) => s.kind === "ok").length,
        bad: review.filter((s) => s.kind === "bad").length,
        miss: missed.length,
      },
      // Сколько несказанных кусков осталось без перевода: расхождение между
      // нашими границами и перечислением модели видно только здесь.
      missing_translated: missed.filter((s) => (s.means ?? "").length > 0).length,
      missing_raw: Array.isArray(parsed.missing) ? parsed.missing.length : 0,
      raw: raw.slice(0, 2000),
    },
  };
}

/** Правильный перевод одной строкой — для озвучки и для плашки. */
export { correctText };
