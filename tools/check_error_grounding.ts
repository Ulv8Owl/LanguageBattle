// Правка на плашке обязана быть взята из перевода САМОЙ МОДЕЛИ.
//
// Разбор показывает игроку две вещи подряд: ленту с правильным вариантом и
// плашки с объяснениями. Когда модель чинит фразу игрока вместо того, чтобы
// переводить задание, эти две вещи противоречат друг другу — и вторая
// неверна. Здесь проверяется отсев таких правок на настоящем случае из игры.
//
// Запуск: deno run --allow-env tools/check_error_grounding.ts
import { asErrors, groundedIn } from "../supabase/functions/_shared/omniJudge.ts";

let failed = 0;
function check(name: string, actual: unknown, expected: unknown) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed++;
  console.log(`${ok ? "OK  " : "FAIL"} ${name}: ${JSON.stringify(actual)}`);
}

// Настоящий раунд: «Я студент и я учу испанский. Мои занятия в понедельник
// и четверг». Модель перевела верно, а на плашке починила только предлог.
const correct = "I am a student and I study Spanish. My lessons are on Monday and Thursday.";

check("правка из перевода — принимается", groundedIn("on Monday and Thursday", correct), true);
check("правка мимо перевода — отсеивается", groundedIn("on Sunday and Saturday", correct), false);
check("пустая правка — плашка живёт объяснением", groundedIn("", correct), true);
check("регистр и точки не считаются", groundedIn("i am a student.", correct), true);

check(
  "из двух ошибок остаётся согласованная",
  asErrors(
    [
      { said: "in Sunday and Saturday", fix: "on Sunday and Saturday", why: "предлог" },
      { said: "I am student", fix: "I am a student", why: "артикль" },
    ],
    correct,
  ).map((e) => e.text),
  ["I am student"],
);

console.log(failed === 0 ? "\nвсё сходится" : `\nрасхождений: ${failed}`);
if (failed > 0) Deno.exit(1);
