// Сверка формулы балла: настоящая scoreFor против случаев из
// test/omni_scoring_test.dart.
//
// ЗАЧЕМ ОТДЕЛЬНЫЙ СКРИПТ. Формула живёт в Deno (Edge Function), а тесты
// проекта — на Flutter, и запустить одну из другой нечем. Поэтому в тесте
// лежит копия формулы, а этот скрипт проверяет, что копия не разошлась с
// оригиналом. Расхождение он уже ловил: значения совпали не там, где я
// ожидал, и выяснилось это числами, а не чтением кода.
//
// Запуск: deno run --allow-read --allow-env tools/check_score_formula.ts
import { correctText, type ReviewSpan, scoreFor } from "../supabase/functions/_shared/review.ts";
import { diffWords } from "../supabase/functions/_shared/textDiff.ts";

const ok = (text: string): ReviewSpan => ({ kind: "ok", text });
const bad_ = (text: string): ReviewSpan => ({ kind: "bad", text });
const miss = (text: string): ReviewSpan => ({ kind: "miss", text });

const cases: [string, ReviewSpan[], number, number][] = [
  ["всё сказано, ошибок нет", [ok("He starts work at six")], 0, 10],
  ["не сказано 60%", [ok("0123"), miss("456789")], 0, 4],
  ["три ошибки", [ok("He starts work at six")], 3, 7],
  ["половина не сказана плюс две ошибки", [ok("01234"), miss("56789")], 2, 3],
  ["ниже единицы не опускаемся", [miss("0123456789")], 5, 1],
  ["сказанное не так в знаменатель не идёт",
    [ok("01234"), bad_("очень длинная чушь"), miss("56789")], 0, 5],
  ["разбора нет — только ошибки", [], 2, 8],
];

let bad = 0;
for (const [name, review, errors, expected] of cases) {
  const got = scoreFor(review, errors);
  if (got !== expected) {
    bad++;
    console.log(`РАСХОЖДЕНИЕ «${name}»: scoreFor(..., ${errors}) = ${got}, в тесте ${expected}`);
  }
}
// Лента считается диффом услышанного с переводом. Случаи взяты из
// настоящих раундов: «половина фразы» приходила с баллом 10, потому что
// разметку рисовала модель и объявляла её безошибочной.
function ribbon(heard: string, correct: string): ReviewSpan[] {
  const out: ReviewSpan[] = [];
  for (const part of diffWords(heard, correct)) {
    const kind = part.kind === "same" ? "ok" : part.kind === "wrong" ? "bad" : "miss";
    const last = out[out.length - 1];
    if (last && last.kind === kind) last.text += " " + part.text;
    else out.push({ kind, text: part.text } as ReviewSpan);
  }
  for (let i = 0; i < out.length - 1; i++) out[i].text += " ";
  return out;
}

const ribbons: [string, string, string, number, number][] = [
  [
    "сказана половина фразы",
    "This shop is open every day.",
    "This shop is open every day. I buy bread and milk here.",
    0,
    5,
  ],
  [
    "сказано всё верно",
    "This shop is open every day. I buy bread and milk here.",
    "This shop is open every day. I buy bread and milk here.",
    0,
    10,
  ],
  [
    "оговорка плюс пропуск",
    "I get up at seven. After that I make coffee.",
    "I get up at seven. Then I make coffee and read the news.",
    1,
    5,
  ],
];

for (const [name, heard, correct, errors, expected] of ribbons) {
  const review = ribbon(heard, correct);
  const got = scoreFor(review, errors);
  if (got !== expected) {
    bad++;
    console.log(`РАСХОЖДЕНИЕ «${name}»: балл ${got}, ожидали ${expected}`);
  }
  // Склейка обязана дать перевод целиком: по ней озвучивается образец.
  const assembled = correctText(review).replace(/\s+/g, " ").trim();
  if (assembled !== correct.replace(/\s+/g, " ").trim()) {
    bad++;
    console.log(`РАСХОЖДЕНИЕ «${name}»: склеилось «${assembled}», ожидали «${correct}»`);
  }
}

console.log(bad === 0 ? "формула, лента и склейка совпадают" : `разошлись в ${bad} случаях`);
if (bad > 0) Deno.exit(1);
