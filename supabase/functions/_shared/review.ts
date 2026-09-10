/**
 * Разбор ответа игрока: всё, что НЕ ЗАВИСИТ от того, кто его судил.
 *
 * ЗАЧЕМ ЭТОТ ФАЙЛ ОТДЕЛЬНО. В ветке LLM судья другой — распознавание плюс
 * текстовая модель вместо одной мультимодальной, — но лента разбора, балл,
 * проверки правок и формат ответа для приложения обязаны остаться теми же.
 * Иначе сравнивать две архитектуры будет не с чем: разница в цифрах пойдёт
 * не от модели, а от того, что мы по-разному считаем.
 *
 * Здесь поэтому лежит ровно то, что общее: типы ответа, склейка ленты,
 * формула балла, отсев придирок и транспорт до провайдера. Кто именно
 * добывает расшифровку и разбор — дело textJudge.ts.
 *
 * ПРОТОКОЛ. Сервис OpenAI-совместимый (DashScope/qwencloud), поэтому запрос
 * выглядит как /chat/completions. Ключ один на все модели ветки:
 * распознавание и текстовый судья ходят по одному и тому же адресу с одним
 * и тем же ключом.
 */

export interface JudgeError {
  /** Фрагмент того, что игрок сказал, — к нему привязано объяснение. */
  text: string;
  /** Объяснение на родном языке игрока. */
  message: string;
  /** Как надо было сказать. Пусто — модель не предложила. */
  correction: string;
}

/** Вид куска в разборе. */
import { type DiffKind, diffWords } from "./textDiff.ts";

export type SpanKind =
  /** Сказано верно — обычный текст. */
  | "ok"
  /** Сказано, но не так — зачёркивается. Это слова ИГРОКА. */
  | "bad"
  /** Не сказано вовсе — красным. Это слова правильного перевода. */
  | "miss";

/** Один кусок разбора: текст и что с ним не так. */
export interface ReviewSpan {
  text: string;
  kind: SpanKind;
}

export interface JudgeResult {
  /**
   * Разбор одной лентой: правильный перевод, в который вплетено то, что
   * игрок сказал не так.
   *
   * ПОЧЕМУ ОДНОЙ ЛЕНТОЙ, А НЕ ДВУМЯ СПИСКАМИ. Раньше модель отдавала
   * отдельно перевод и отдельно список пропущенных кусков, а приложение
   * искало вторые в первом подстрокой. Поиск промахивался на каждой мелочи
   * — модель цитировала неточно, меняла регистр, — и подсветка молча
   * пропадала. Здесь границы уже проведены самой моделью: приложению
   * остаётся покрасить, а не догадываться.
   */
  review: ReviewSpan[];
  /** Ошибки, найденные моделью. Пустой список — сказано верно. */
  errors: JudgeError[];
  /**
   * Слышна ли в записи речь.
   *
   * Стоит одного слова в ответе и ловит самый опасный сбой: модель, до
   * которой аудио не доехало, отвечает СВОИМ переводом без единой ошибки —
   * то есть игрок получает десятку за что угодно, и по ответу этого не
   * видно. Явный вопрос превращает молчаливую ложь в честный отказ.
   */
  audible: boolean;
  /** Модель не ответила или ответила не тем. Балл тогда нейтральный. */
  degraded: boolean;
  /**
   * Модель послушала запись и речи в ней не разобрала.
   *
   * ОТДЕЛЬНО ОТ degraded, и это главное различие в этом файле. degraded —
   * наш сбой: мы не знаем, как игрок ответил, и ставим нейтральный балл.
   * silent — мы знаем: разобрать было нечего. Раньше оба случая шли одной
   * веткой, и невнятная запись получала те же семь баллов, что и молчащий
   * провайдер.
   */
  silent?: boolean;
  /**
   * Игрок говорил не на том языке — и модель это назвала сама.
   *
   * ЗАЧЕМ ОТДЕЛЬНЫЙ ВОПРОС. Модель, которой сказали «сейчас будет
   * английский», в русской речи слышит похожие на английские слова и
   * записывает их как сказанные: половина «перевода» засчитывалась верной.
   * Ожидание языка — этого достаточно, чтобы его «услышать». Явный вопрос
   * «а что за язык ты вообще слышал» ловит это одним словом.
   *
   * ВТОРОГО РАСПОЗНАВАТЕЛЯ ЗДЕСЬ НЕТ. Распознаётся по-прежнему один язык —
   * мы только просим модель честно сказать, тот ли он.
   */
  wrongLanguage?: boolean;
  /** Язык, который модель услышала. Пусто — она его не назвала. */
  spokenLanguage?: string;
  failureReason?: string;
  debug: Record<string, unknown>;
}

/**
 * Склеивает пословный дифф в ленту кусков.
 *
 * Дифф работает по словам, а на экране нужны цельные фрагменты: десять
 * подряд верных слов — это один кусок обычного текста, а не десять
 * одинаковых. Заодно здесь расставляются пробелы: слова приходят голыми,
 * и без этого фраза слиплась бы в одно длинное слово.
 */
export function ribbon(parts: { text: string; kind: DiffKind }[]): ReviewSpan[] {
  const out: ReviewSpan[] = [];
  for (const part of parts) {
    const kind: SpanKind = part.kind === "same" ? "ok" : part.kind === "wrong" ? "bad" : "miss";
    const last = out[out.length - 1];
    if (last && last.kind === kind) last.text += " " + part.text;
    else out.push({ kind, text: part.text });
  }
  // Пробел на стыке групп: без него «morning» и «then» слипались в
  // «morningthen» — это игрок видел на экране.
  for (let i = 0; i < out.length - 1; i++) out[i].text += " ";
  return out;
}

/** Правильный перевод — всё, кроме сказанного игроком неверно. */
export function correctText(review: ReviewSpan[]): string {
  return review.filter((s) => s.kind !== "bad").map((s) => s.text).join("");
}

/**
 * Балл за ответ считает ПРОГРАММА, а не модель.
 *
 * Числовая оценка от модели была самой шаткой частью ответа: на одной и
 * той же записи она гуляла на два-три балла и объяснить её игроку было
 * нечем. Арифметика по её же разбору повторяема и проговаривается одной
 * фразой — «половину не сказал и две ошибки».
 *
 * Формула: из десяти вычитаем долю несказанного (не сказал 60% — минус 6)
 * и по баллу за каждую отдельную ошибку.
 *
 * Ниже единицы не опускаемся, и ноль сюда не попадает НИКОГДА: сюда мы
 * доходим только когда модель речь разобрала, то есть игрок что-то сказал.
 * Ноль означает другое — «в записи нечего разбирать» (SILENT_SCORE), и
 * смешать эти два случая в одном числе значило бы снова выдать сбой за
 * оценку.
 */
export function scoreFor(review: ReviewSpan[], errorCount: number): number {
  const len = (kind: SpanKind) =>
    review.filter((s) => s.kind === kind).reduce((sum, s) => sum + s.text.trim().length, 0);
  const total = len("ok") + len("miss");
  // Перевода нет — считать долю не от чего. Тогда единственное, что у нас
  // есть, это ошибки: пусть отвечают только они.
  const share = total === 0 ? 0 : Math.min(1, len("miss") / total);
  const score = 10 - Math.round(10 * share) - errorCount;
  return Math.max(1, Math.min(10, score));
}

const DEFAULT_BASE = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1";

/**
 * КЛЮЧ ОДИН НА ВСЮ ВЕТКУ. Распознавание и текстовый судья — это разные
 * модели, но один провайдер (qwencloud/DashScope) и один счёт. Два секрета
 * для одного ключа означали бы, что однажды обновят только один.
 *
 * Имя `OMNI_API_KEY` принимается вторым: ветка выросла из мультимодальной,
 * и заставлять переставлять уже заведённый секрет ради переименования —
 * это работа без результата.
 */
function secret(...names: string[]): string | null {
  for (const name of names) {
    const value = Deno.env.get(name);
    if (value && value.length > 0) return value;
  }
  return null;
}

export function judgeEnabled(): boolean {
  return (secret("QWEN_ENABLED", "OMNI_ENABLED") ?? "0") === "1";
}

export function judgeKey(): string | null {
  return secret("QWEN_API_KEY", "OMNI_API_KEY");
}

export function judgeBaseUrl(): string {
  return secret("QWEN_BASE_URL", "OMNI_BASE_URL") ?? DEFAULT_BASE;
}

const TIMEOUT_MS = Number(secret("QWEN_TIMEOUT_MS", "OMNI_TIMEOUT_MS") ?? "90000");

/** Меньше этого запускать вызов бессмысленно — он не успеет вернуться. */
const MIN_SLICE_MS = 8_000;

const LANGUAGE_NAMES: Record<string, string> = {
  en: "English",
  ru: "Russian",
  es: "Spanish",
};

/**
 * Название языка НА НЁМ САМОМ.
 *
 * Нужно рядом с английским названием, и это не украшение. Инструкция
 * «explain in Russian» модель однажды прочитала как пожелание и ответила
 * по-испански — игрок с русским в паре получил разбор на языке, которого
 * не выбирал. Самоназвание работает как второй, независимый указатель: его
 * трудно перепутать, потому что оно написано той же письменностью, что и
 * требуемый ответ.
 */
const LANGUAGE_ENDONYMS: Record<string, string> = {
  en: "English",
  ru: "русский",
  es: "español",
};

export function languageName(code: string): string {
  return LANGUAGE_NAMES[code.toLowerCase()] ?? code;
}

export function languageEndonym(code: string): string {
  return LANGUAGE_ENDONYMS[code.toLowerCase()] ?? code;
}

/**
 * Тот ли язык назвала модель.
 *
 * Сравнение по названию, а не по коду: код мы у неё не просим — на вопрос
 * «какой язык» модель отвечает словом, и просить вместо этого ISO-код
 * значит добавить ей повод ошибиться на ровном месте. Сравниваем мягко:
 * "English", "english", "англ. English" — всё это про один язык.
 *
 * НЕИЗВЕСТНОЕ НАЗВАНИЕ СЧИТАЕТСЯ СВОИМ. Если мы не знаем языка (реестр
 * шире, чем список названий), отказать игроку было бы хуже, чем пропустить
 * редкий случай: он получит разбор, а не отказ ни за что.
 */
export function sameLanguage(spoken: string, targetCode: string): boolean {
  const said = spoken.toLowerCase();
  const target = languageName(targetCode).toLowerCase();
  if (said.includes(target)) return true;
  // Название какого-то ДРУГОГО известного языка — значит точно не наш.
  for (const [code, name] of Object.entries(LANGUAGE_NAMES)) {
    if (code === targetCode.toLowerCase()) continue;
    if (said.includes(name.toLowerCase())) return false;
  }
  return true;
}

export function base64(bytes: Uint8Array): string {
  // По кускам: у аудио раунда десятки-сотни килобайт, и одним
  // String.fromCharCode(...bytes) на таком размере рвётся стек аргументов.
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/**
 * Собирает текст из потокового ответа.
 *
 * stream обязателен для этой модели, поэтому разбор SSE — не оптимизация, а
 * единственный доступный способ прочитать ответ.
 */
async function readStream(res: Response): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) throw new Error("пустой поток ответа");
  const decoder = new TextDecoder();
  let buffer = "";
  let text = "";

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    // События разделены пустой строкой; последний кусок буфера может быть
    // оборван на середине, поэтому его оставляем до следующей порции.
    const parts = buffer.split("\n");
    buffer = parts.pop() ?? "";
    for (const line of parts) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("data:")) continue;
      const payload = trimmed.slice(5).trim();
      if (payload === "[DONE]") continue;
      try {
        const chunk = JSON.parse(payload);
        const delta = chunk?.choices?.[0]?.delta;
        if (typeof delta?.content === "string") text += delta.content;
      } catch {
        // Обрывок, который не разобрался как JSON, — не повод ронять
        // весь ответ: следующие события всё равно принесут содержимое.
      }
    }
  }
  return text;
}

/** Достаёт JSON-объект из ответа, даже если модель обернула его в текст. */
export function parseJson(raw: string): Record<string, unknown> | null {
  const trimmed = raw.trim();
  const candidates = [trimmed];
  // Модель может обернуть ответ в ```json ... ``` вопреки инструкции.
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced) candidates.push(fenced[1]);
  const braced = trimmed.match(/\{[\s\S]*\}/);
  if (braced) candidates.push(braced[0]);

  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
    } catch {
      // Пробуем следующий вариант.
    }
  }
  return null;
}

/**
 * Слова строки в том же виде, в каком их сравнивает лента разбора.
 * Пунктуация и регистр не считаются: их в речи нет.
 */
function wordsOf(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^\p{L}\p{N}']+/u)
    .filter((w) => w.length > 0);
}

/**
 * Взята ли правка из перевода САМОЙ МОДЕЛИ.
 *
 * ЗАЧЕМ. Модель охотно чинит фразу игрока вместо того, чтобы переводить
 * задание. На «My lesson in Sunday and Saturday» она показала в ленте
 * правильное «My lessons are on Monday and Thursday», а на плашке к той же
 * ошибке написала «on Sunday and Saturday»: предлог поправила, а
 * перепутанные дни оставила. Игрок читает два разных правильных ответа
 * подряд, и второй — неверный.
 *
 * Правка, слов которой нет в переводе, — это правка не туда: либо перевод
 * у модели другой, либо ошибки нет вовсе. Показывать её нельзя, и снимать
 * за неё балл тем более.
 */
export function groundedIn(fix: string, correct: string): boolean {
  const words = wordsOf(fix);
  if (words.length === 0) return true;
  const reference = new Set(wordsOf(correct));
  return words.every((w) => reference.has(w));
}

/**
 * Сказал ли игрок то, что ему приписали на плашке.
 *
 * Плашка устроена как цитата: сверху «вот твои слова», под ними правка.
 * Слова, которых в расшифровке нет, — это не цитата, а пересказ: игрок
 * читает про ошибку, которой не делал, и ищет её в своей речи.
 *
 * Сравниваем по словам, а не по подстроке: модель цитирует с другим
 * регистром и без запятых, и придираться к этому значило бы терять
 * настоящие ошибки.
 */
export function saidIn(said: string, heard: string): boolean {
  const words = wordsOf(said);
  if (words.length === 0) return false;
  const spoken = new Set(wordsOf(heard));
  return words.every((w) => spoken.has(w));
}

/**
 * Виды ошибок, за которые снимается балл.
 *
 * Всё, что сюда не попадает, — придирка. Модель обязана назвать вид ДО
 * того, как напишет объяснение: фрагмент, который не удаётся отнести ни к
 * одному из трёх, и был в порядке. Стиля, регистра, «звучит естественнее»
 * в списке нет намеренно — это и есть та ошибка, за которую нельзя
 * наказывать.
 */
const ERROR_KINDS = new Set(["meaning", "grammar", "word"]);

/**
 * Обороты, которыми объясняют придирку, а не ошибку.
 *
 * ЗАЧЕМ ЭТО В КОДЕ. Промпт запрещает такие доводы «на любом языке», но
 * запрет написан по-английски, а объяснение модель пишет игроку на его
 * языке — и запрет до него не доезжает. Игроку приходило «потому что
 * "Then" короче и чаще используется» и «потому что это более обычное
 * выражение»: ровно то, что запрещено, слово в слово, только по-русски.
 * Проверка в коде — единственный способ, которым это правило вообще
 * может выполняться, а не просто быть написанным.
 *
 * ЯЗЫКОВ ТРИ, И ЭТОГО ХВАТАЕТ: объяснение пишется на родном языке игрока,
 * а банк фраз есть только для ru/en/es. Появится четвёртый — список сюда
 * дописывается, и до тех пор он просто не срабатывает.
 *
 * ЧЕМ ЭТО РИСКУЕТ. Настоящую ошибку, объяснённую через частотность («мы
 * чаще говорим at перед временем»), тоже отсеет. Это осознанный размен:
 * потерять один разбор не так дорого, как объявить верную фразу ошибкой и
 * снять за неё балл.
 */
const NITPICK_REASONS = [
  // русский
  "естественн",
  "натуральн",
  "чаще говор",
  "чаще использ",
  "чаще употреб",
  "более обычн",
  "обычно говор",
  "принято говор",
  "привычн",
  "носител",
  "звучит лучше",
  "звучит красив",
  "лучше сказать",
  "лучше звучит",
  "короче",
  // english
  "more natural",
  "sounds better",
  "sounds more",
  "usually say",
  "native speaker",
  "more common",
  "commonly used",
  "more idiomatic",
  "is shorter",
  // espanol
  "mas natural",
  "más natural",
  "suena mejor",
  "mas comun",
  "más común",
  "hablantes nativos",
  "se suele decir",
  "mas corto",
  "más corto",
];

/** Объяснение, в котором вся причина — «так говорят чаще». */
export function nitpickReason(why: string): boolean {
  const text = why.toLowerCase();
  return NITPICK_REASONS.some((phrase) => text.includes(phrase));
}

export function asErrors(raw: unknown, correct: string, heard: string): JudgeError[] {
  if (!Array.isArray(raw)) return [];
  const out: JudgeError[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const row = item as Record<string, unknown>;
    // Ключи короткие (said/fix/why): каждый повторяется в ответе столько
    // раз, сколько нашлось ошибок, и на длинном разборе это заметные
    // токены за нулевую пользу.
    const text = typeof row.said === "string" ? row.said.trim() : "";
    const message = typeof row.why === "string" ? row.why.trim() : "";
    // Ошибка без фрагмента показывается не к чему: плашка в разборе — это
    // и есть фрагмент. Ошибка без объяснения — пустая плашка, за которой
    // ничего нет; такую лучше не показывать вовсе, чем обещать разбор.
    const correction = typeof row.fix === "string" ? row.fix.trim() : "";
    if (text.length === 0 || message.length === 0) continue;
    // «Сказал X, надо X» — это не ошибка, а пропуск, выданный за ошибку.
    // Модель делает так регулярно, и каждый такой ложный пункт снимал бы
    // балл второй раз: доля несказанного его уже учла.
    if (correction.length > 0 && correction === text) continue;
    // Правка расходится с переводом самой модели — см. groundedIn.
    if (!groundedIn(correction, correct)) continue;
    // Модель сама отнесла ошибку к стилю или к чему-то ещё вне списка —
    // значит по существу претензии нет. Отсутствующий вид пропускаем:
    // модель могла просто не заполнить поле, и терять из-за этого
    // настоящие ошибки хуже, чем пропустить одну придирку.
    const kind = typeof row.kind === "string" ? row.kind.trim().toLowerCase() : "";
    if (kind.length > 0 && !ERROR_KINDS.has(kind)) continue;
    // Вид назван верно, а доводом всё равно оказалась частотность —
    // см. NITPICK_REASONS. Ошибку модель придумала уже после того, как
    // выбрала ей вид.
    if (nitpickReason(message)) continue;
    // Плашка цитирует игрока — значит цитата должна быть из его речи.
    if (!saidIn(text, heard)) continue;
    out.push({
      text,
      message,
      correction,
    });
  }
  return out;
}

/**
 * Один HTTP-вызов модели: система + части пользовательского сообщения.
 *
 * Вынесен, чтобы протокол — капризный и неочевидный (обязательный stream,
 * modalities, разбор SSE) — жил в одном месте, а не расползался по вызовам
 * вместе с их особенностями.
 */
/**
 * Один HTTP-вызов провайдера: система + части пользовательского сообщения.
 *
 * ОБЩИЙ ДЛЯ ОБОИХ ШАГОВ ветки — и для распознавания, и для судьи. Протокол
 * у них один: тот же адрес, тот же ключ, тот же разбор потока. Две копии
 * этого кода разошлись бы на первой же особенности провайдера.
 *
 * `modalities` уходит только тогда, когда в запросе есть аудио: текстовые
 * модели на незнакомое поле отвечают HTTP 400, и добавлять его «на всякий
 * случай» значит ломать половину списка моделей.
 */
export async function requestQwen(
  system: string,
  userParts: unknown[],
  budgetMs: number,
  model: string,
  opts: { audio?: boolean; temperature?: number } = {},
): Promise<{ raw: string } | { error: string }> {
  const key = judgeKey();
  if (!key) {
    return { error: "нет ключа модели: npx supabase secrets set QWEN_API_KEY=<ключ>" };
  }
  const timeoutMs = Math.min(TIMEOUT_MS, budgetMs);
  if (timeoutMs < MIN_SLICE_MS) {
    return { error: `на вызов осталось ${Math.round(budgetMs / 1000)}с — меньше минимума` };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${judgeBaseUrl()}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: system },
          { role: "user", content: userParts },
        ],
        // Только текст: озвучка у нас своя, и просить у модели ещё и аудио
        // значило бы платить за то, что тут же выбросим. Текстовые модели
        // этого поля не знают, поэтому оно едет лишь со звуком.
        ...(opts.audio ? { modalities: ["text"] } : {}),
        // Обязателен для аудио-моделей — без него сервис отвечает ошибкой.
        // Текстовым он безразличен, а разбор потока у нас один на всех.
        stream: true,
        stream_options: { include_usage: true },
        temperature: opts.temperature ?? 0.2,
      }),
      signal: controller.signal,
    });

    if (!res.ok) {
      const body = await res.text().catch(() => "");
      return { error: `HTTP ${res.status}: ${body.slice(0, 400)}` };
    }
    return { raw: await readStream(res) };
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") {
      return { error: `вызов не уложился в ${Math.round(timeoutMs / 1000)}с` };
    }
    return { error: `сбой вызова: ${e}` };
  } finally {
    clearTimeout(timer);
  }
}
