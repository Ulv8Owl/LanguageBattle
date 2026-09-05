/**
 * Оценка ответа ПО ЭЛЕМЕНТАМ — без обращения к языковой модели.
 *
 * Фраза раунда приходит из банка уже разбитой на элементы: разделитель «|»
 * стоит в исходнике (assets/cefr/*.txt) и доезжает до сервера в
 * generated_phrase. Элемент — это смысловой кусок в два-пять слов («at
 * seven», «and read the news»), и оценка теперь отвечает на один прямой
 * вопрос: сколько таких кусков игрок произнёс, а сколько потерял.
 *
 * ЗАЧЕМ ЭТО ВМЕСТО СУДЬИ-LLM. У модели оценка субъективна, стоит денег,
 * занимает десятки секунд и иногда не приходит вовсе (статус degraded).
 * Поэлементная оценка детерминирована, считается за микросекунды и
 * объясняется игроку одной фразой — «три куска из шести». Разбор ошибок
 * при этом не пропадает: к каждому элементу в датасете написано пояснение,
 * и клиент показывает его по тапу. Код судьи остаётся на месте и
 * включается переменной окружения (см. evaluateGrammar.ts).
 *
 * ЧЕГО ЭТА ОЦЕНКА НЕ ДЕЛАЕТ. Она не проверяет грамматику: сказанное
 * «I goes to work» засчитает элемент «I go to work» как произнесённый, если
 * слова совпали. Это осознанный размен на время, пока судья выключен.
 */

/** Один элемент эталонной фразы. */
export interface ExpectedElement {
  /** Слова элемента, как они записаны в банке. */
  text: string;
  /** Смещение начала [text] в чистой фразе (без «|») — для grammar_errors. */
  offset: number;
}

export interface ElementVerdict extends ExpectedElement {
  /** Сколько слов элемента нашлось в ответе игрока. */
  matchedWords: number;
  totalWords: number;
  correct: boolean;
}

export interface ElementScore {
  verdicts: ElementVerdict[];
  correctCount: number;
  totalCount: number;
  /** Балл 1..10 — то, что уходит в round_scores/training_rounds. */
  score: number;
}

/**
 * Какая доля слов элемента должна найтись в ответе, чтобы засчитать его.
 *
 * Не 1.0 намеренно. Элемент — это два-пять слов, и распознавание речи
 * неносителя регулярно теряет артикль или предлог, которого игрок на самом
 * деле не пропускал. Требовать все слова значило бы наказывать за ошибку
 * распознавателя. 0.6 даёт: из двух слов нужны оба, из трёх — два, из пяти
 * — три. Тот же порог, что и у проверки уровня при регистрации, и по той
 * же причине: это граница между «в целом сказал» и «в целом не сказал».
 */
export const ELEMENT_MATCH_RATIO = 0.6;

/** Балл, когда не совпало вообще ничего. Тот же, что за тишину. */
const MIN_SCORE = 1;
const MAX_SCORE = 10;

/**
 * Нормализация слова: регистр и пунктуация не считаются ошибкой.
 *
 * Распознаватель сам расставляет точки и заглавные буквы там, где игрок
 * просто сделал паузу. Ровно та же нормализация — в клиентском
 * lib/core/text_diff.dart, и расходиться им нельзя: игрок увидел бы
 * подсветку, не совпадающую с баллом.
 */
function normalize(word: string): string {
  return word
    .toLowerCase()
    .replace(/[^\p{L}\p{N}']/gu, "");
}

function tokenize(text: string): string[] {
  return text
    .split(/\s+/)
    .map((w) => w.trim())
    .filter((w) => w.length > 0);
}

/**
 * Разбирает эталонную фразу с «|» на элементы со смещениями в ЧИСТОЙ фразе.
 *
 * Пустой список означает, что разделителей в строке нет вовсе — фраза
 * старого формата. Вызывающий код обязан это отличать: оценивать такую
 * фразу поэлементно нечем.
 */
export function parseElements(marked: string): ExpectedElement[] {
  if (!marked.includes("|")) return [];
  const parts = marked.split("|");
  // Последний кусок — хвост после последнего разделителя (обычно точка),
  // элементом он не является.
  const body = parts.slice(0, -1);

  const elements: ExpectedElement[] = [];
  let offset = 0;
  for (const part of body) {
    // Ведущая пунктуация и пробелы принадлежат границе предложений, а не
    // элементу: «. Then I make» — элемент здесь «Then I make».
    const lead = part.match(/^[\s.,;:!?…—–-]*/)?.[0] ?? "";
    const text = part.slice(lead.length);
    offset += lead.length;
    if (text.trim().length > 0) {
      elements.push({ text, offset });
    }
    offset += text.length;
  }
  return elements;
}

/**
 * Какие слова эталона игрок произнёс.
 *
 * Наибольшая общая подпоследовательность: слово засчитывается, только если
 * оно сказано И в верном порядке относительно остальных. Тот же алгоритм,
 * что в клиентском diffWords, — иначе подсветка расходилась бы с баллом.
 */
function matchedFlags(expectedWords: string[], spokenWords: string[]): boolean[] {
  const a = expectedWords.map(normalize).filter((w) => w.length > 0);
  const b = spokenWords.map(normalize).filter((w) => w.length > 0);
  // Сохраняем соответствие «нормализованное слово -> индекс исходного».
  const indexMap: number[] = [];
  expectedWords.forEach((w, i) => {
    if (normalize(w).length > 0) indexMap.push(i);
  });

  const lcs: number[][] = Array.from(
    { length: a.length + 1 },
    () => new Array<number>(b.length + 1).fill(0),
  );
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j]
        ? lcs[i + 1][j + 1] + 1
        : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }

  const flags = new Array<boolean>(expectedWords.length).fill(false);
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      flags[indexMap[i]] = true;
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return flags;
}

/**
 * Считает балл и поэлементный вердикт.
 *
 * [marked] — эталон с «|», [transcript] — то, что распознали.
 * Возвращает null, если эталон без разделителей: оценивать нечем, и
 * вызывающий код должен обработать это явно, а не получить балл из
 * ниоткуда.
 */
export function scoreByElements(marked: string, transcript: string): ElementScore | null {
  const elements = parseElements(marked);
  if (elements.length === 0) return null;

  const spoken = tokenize(transcript);
  // Слова эталона идут подряд по всем элементам — выравнивание общее, а не
  // поэлементное: иначе одно и то же слово ответа могло бы закрыть сразу
  // два разных элемента.
  const expectedWords: string[] = [];
  const ownerOfWord: number[] = [];
  elements.forEach((element, index) => {
    for (const word of tokenize(element.text)) {
      expectedWords.push(word);
      ownerOfWord.push(index);
    }
  });

  const flags = matchedFlags(expectedWords, spoken);

  const matched = new Array<number>(elements.length).fill(0);
  const totals = new Array<number>(elements.length).fill(0);
  expectedWords.forEach((_, i) => {
    const owner = ownerOfWord[i];
    totals[owner]++;
    if (flags[i]) matched[owner]++;
  });

  const verdicts: ElementVerdict[] = elements.map((element, index) => {
    const total = totals[index];
    const hit = matched[index];
    return {
      ...element,
      matchedWords: hit,
      totalWords: total,
      correct: total === 0 ? false : hit / total >= ELEMENT_MATCH_RATIO,
    };
  });

  const correctCount = verdicts.filter((v) => v.correct).length;
  const totalCount = verdicts.length;
  const score = Math.min(
    MAX_SCORE,
    Math.max(MIN_SCORE, Math.round((correctCount / totalCount) * MAX_SCORE)),
  );

  return { verdicts, correctCount, totalCount, score };
}
