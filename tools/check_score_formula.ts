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
import { scoreFor } from "../supabase/functions/_shared/omniJudge.ts";

const cases: [string, string[], number, number][] = [
  ["He starts work at six", [], 0, 10],
  ["0123456789", ["012345"], 0, 4],
  ["He starts work at six", [], 3, 7],
  ["0123456789", ["01234"], 2, 3],
  ["0123456789", ["0123456789"], 5, 1],
  ["aaaa bbbb", ["aaaa"], 0, 6],
  ["aaaa bbbb", ["aaaa", "aaaa"], 0, 6],
  ["", ["что угодно"], 2, 8],
];

let bad = 0;
for (const [correct, missing, errors, expected] of cases) {
  const got = scoreFor(correct, missing, errors);
  if (got !== expected) {
    bad++;
    console.log(
      `РАСХОЖДЕНИЕ scoreFor(${JSON.stringify(correct)}, ${JSON.stringify(missing)}, ${errors})` +
        ` = ${got}, в тесте ${expected}`,
    );
  }
}
console.log(bad === 0 ? "формулы совпадают" : `разошлись в ${bad} случаях`);
if (bad > 0) Deno.exit(1);
