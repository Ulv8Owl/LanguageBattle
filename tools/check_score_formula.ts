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
import { type ReviewSpan, scoreFor } from "../supabase/functions/_shared/omniJudge.ts";

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
console.log(bad === 0 ? "формулы совпадают" : `разошлись в ${bad} случаях`);
if (bad > 0) Deno.exit(1);
