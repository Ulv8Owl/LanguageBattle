// Правка на плашке обязана быть взята из перевода САМОЙ МОДЕЛИ.
//
// Разбор показывает игроку две вещи подряд: ленту с правильным вариантом и
// плашки с объяснениями. Когда модель чинит фразу игрока вместо того, чтобы
// переводить задание, эти две вещи противоречат друг другу — и вторая
// неверна. Здесь проверяется отсев таких правок на настоящем случае из игры.
//
// Запуск: deno run --allow-env tools/check_error_grounding.ts
import { asErrors, groundedIn, nitpickReason, saidIn } from "../supabase/functions/_shared/review.ts";

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
    "I am student and I study Spanish. My lessons in Sunday and Saturday.",
  ).map((e) => e.text),
  ["I am student"],
);

// Вид ошибки — обязательная самопроверка модели. Стиля в списке нет: за
// «звучит естественнее» балл не снимается.
check(
  "придирка по стилю отсеивается",
  asErrors(
    [{ said: "After that", fix: "Then", kind: "style", why: "так лучше" }],
    correct,
    "After that I am student",
  ).length,
  0,
);
check(
  "настоящая ошибка со своим видом остаётся",
  asErrors(
    [{ said: "I am student", fix: "I am a student", kind: "grammar", why: "артикль" }],
    correct,
    "I am student",
  ).map((e) => e.text),
  ["I am student"],
);
check(
  "вид не назван — ошибку не теряем",
  asErrors([{ said: "I am student", fix: "I am a student", why: "артикль" }], correct, "I am student")
    .map((e) => e.text),
  ["I am student"],
);

// НАСТОЯЩИЙ РАУНД СО СКРИНШОТОВ. Первая фраза банка A1: «Я встаю в семь
// каждое утро. Потом я делаю кофе и читаю новости». Игрок сказал её верно
// своими словами, а модель выдала три ошибки подряд — все три словами
// нашего образца, с объяснением «в задании сказано Then».
const heard = "I wake up at seven every morning. After that I make coffee and read the news.";

// Так теперь собирается «правильный перевод»: из сказанного игроком.
// Ничего не было сказано неверно — значит менять нечего.
const kept = heard;

check(
  "«надо get up» — правки нет в переводе игрока",
  asErrors(
    [{ said: "wake up", fix: "get up", kind: "word", why: "это более обычное выражение" }],
    kept,
    heard,
  ).length,
  0,
);
check(
  "«надо Then» — правки нет в переводе игрока",
  asErrors(
    [{ said: "after that", fix: "Then", kind: "word", why: "'Then' короче и чаще используется" }],
    kept,
    heard,
  ).length,
  0,
);

// А если модель всё же соберёт «правильный» из образца — доводом остаётся
// частотность, и это ловится отдельно от перевода.
const key = "I get up at seven every morning. Then I make coffee and read the news.";
check(
  "довод «чаще используется» — не довод",
  nitpickReason("В задании сказано 'Then', потому что 'Then' короче и чаще используется"),
  true,
);
check(
  "довод «более обычное выражение» — не довод",
  nitpickReason("Вместо 'wake up' нужно сказать 'get up', потому что это более обычное выражение"),
  true,
);
check("настоящий довод остаётся доводом", nitpickReason("для времени нужен предлог 'at'"), false);
check(
  "придирка словами образца отсеивается и по доводу",
  asErrors(
    [{ said: "wake up", fix: "get up", kind: "word", why: "это более обычное выражение" }],
    key,
    heard,
  ).length,
  0,
);
check(
  "настоящая ошибка в том же раунде остаётся",
  asErrors(
    [{ said: "in seven", fix: "at seven", kind: "grammar", why: "для времени нужен предлог 'at'" }],
    "I wake up at seven every morning.",
    "I wake up in seven every morning.",
  ).map((e) => e.text),
  ["in seven"],
);

// Плашка цитирует игрока — значит цитата должна быть из его речи.
check("цитата из речи — принимается", saidIn("wake up", heard), true);
check("цитата не из речи — отсеивается", saidIn("stand up", heard), false);
check(
  "приписанные слова не показываются",
  asErrors(
    [{ said: "stand up", fix: "get up", kind: "word", why: "не то слово" }],
    "I get up at seven.",
    heard,
  ).length,
  0,
);

console.log(failed === 0 ? "\nвсё сходится" : `\nрасхождений: ${failed}`);
if (failed > 0) Deno.exit(1);
