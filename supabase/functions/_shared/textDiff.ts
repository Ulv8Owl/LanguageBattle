/**
 * Пословное сравнение услышанного с правильным вариантом.
 *
 * ЗАЧЕМ ЭТО НА СЕРВЕРЕ. Разметку разбора — что сказано верно, что не так,
 * что пропущено — раньше рисовала сама модель. Дважды подряд она рисовала
 * её неправильно: то помечала сказанное как пропущенное, то объявляла
 * «ошибок нет» на половине фразы. Причина не в плохой модели, а в том, что
 * задача не для неё: сравнить две строки по словам — арифметика, и
 * арифметику надо считать, а не спрашивать.
 *
 * Теперь модель отвечает только за то, что умеет одна она: услышать,
 * перевести и объяснить. Границы кусков считает этот код, и ошибиться в
 * них он не может.
 *
 * Сравнение идёт по НОРМАЛИЗОВАННЫМ словам (без пунктуации и регистра):
 * модель сама расставляет точки и заглавные буквы там, где игрок просто
 * сделал паузу, и считать это ошибкой нельзя.
 *
 * Порт lib/core/text_diff.dart — тот же алгоритм слово в слово, чтобы
 * сервер и клиент не разошлись в том, что считать правкой.
 */

export type DiffKind =
  /** Слово сказано верно. */
  | "same"
  /** Слово сказано неправильно — в правильном варианте его нет. */
  | "wrong"
  /** Слово пропущено — есть в правильном варианте, но сказано не было. */
  | "missing";

export interface DiffPart {
  text: string;
  kind: DiffKind;
}

function normalize(word: string): string {
  return word.toLowerCase().replace(/[^\p{L}\p{N}']/gu, "");
}

function tokenize(text: string): string[] {
  return text.split(/\s+/).filter((w) => w.trim().length > 0);
}

/**
 * Различия между [spoken] (что услышала модель) и [corrected] (как должно
 * быть). Возвращает правильный текст по порядку, помечая каждое слово.
 *
 * Пустой [corrected] — сравнивать не с чем; всё помечается верным, и
 * вызывающий сам решает, показывать ли разбор вообще.
 */
export function diffWords(spoken: string, corrected: string): DiffPart[] {
  const a = tokenize(spoken);
  const b = tokenize(corrected);
  if (b.length === 0) return a.map((text) => ({ text, kind: "same" as const }));

  const na = a.map(normalize);
  const nb = b.map(normalize);

  // Наибольшая общая подпоследовательность: слова, которые игрок сказал
  // верно и в верном порядке. Всё, что не попало в неё, — либо лишнее у
  // игрока, либо пропущенное им.
  const lcs: number[][] = Array.from(
    { length: na.length + 1 },
    () => new Array<number>(nb.length + 1).fill(0),
  );
  for (let i = na.length - 1; i >= 0; i--) {
    for (let j = nb.length - 1; j >= 0; j--) {
      lcs[i][j] = na[i] === nb[j]
        ? lcs[i + 1][j + 1] + 1
        : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  const parts: DiffPart[] = [];
  let i = 0;
  let j = 0;
  while (i < na.length && j < nb.length) {
    if (na[i] === nb[j]) {
      parts.push({ text: b[j], kind: "same" });
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      parts.push({ text: a[i], kind: "wrong" });
      i++;
    } else {
      parts.push({ text: b[j], kind: "missing" });
      j++;
    }
  }
  while (i < na.length) parts.push({ text: a[i], kind: "wrong" }), i++;
  while (j < nb.length) parts.push({ text: b[j], kind: "missing" }), j++;
  return parts;
}
