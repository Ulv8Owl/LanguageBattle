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
import {
  correctText,
  type ReviewSpan,
  scoreFor,
  withSpacing,
} from "../supabase/functions/_shared/omniJudge.ts";

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
// Склейка ленты: пробел на стыке модель теряет постоянно, и «morningthen»
// игрок видел на экране. Проверяем на настоящих кусках из того разбора.
const spacing: [string, ReviewSpan[], string][] = [
  [
    "точка и следующее предложение",
    [
      { kind: "ok", text: "I get up at seven every morning." },
      { kind: "miss", text: "then I make coffee" },
    ],
    "I get up at seven every morning. then I make coffee",
  ],
  [
    "слово к слову",
    [{ kind: "ok", text: "then I make coffee" }, { kind: "miss", text: "and read the news" }],
    "then I make coffee and read the news",
  ],
  [
    "перед запятой пробел не нужен",
    [{ kind: "ok", text: "coffee" }, { kind: "miss", text: ", then news" }],
    "coffee, then news",
  ],
  [
    "готовый пробел не удваивается",
    [{ kind: "ok", text: "coffee " }, { kind: "miss", text: "and news" }],
    "coffee and news",
  ],
];

for (const [name, review, expected] of spacing) {
  const got = correctText(withSpacing(review));
  if (got !== expected) {
    bad++;
    console.log(`РАСХОЖДЕНИЕ «${name}»: склеилось «${got}», ожидали «${expected}»`);
  }
}

console.log(bad === 0 ? "формулы и склейка совпадают" : `разошлись в ${bad} случаях`);
if (bad > 0) Deno.exit(1);
