// Правка на плашке обязана быть взята из перевода САМОЙ МОДЕЛИ.
//
// Разбор показывает игроку две вещи подряд: ленту с правильным вариантом и
// плашки с объяснениями. Когда модель чинит фразу игрока вместо того, чтобы
// переводить задание, эти две вещи противоречат друг другу — и вторая
// неверна. Здесь проверяется отсев таких правок на настоящем случае из игры.
//
// Запуск: deno run --allow-env tools/check_error_grounding.ts
import { asrFamily, chatText, nativeText } from "../supabase/functions/_shared/asr.ts";
import {
  asErrors,
  attachMeanings,
  groundedIn,
  nitpickReason,
  reviewErrors,
  revertRejectedFixes,
  saidIn,
} from "../supabase/functions/_shared/review.ts";

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

// ═══ ТРИ БАГА, КОТОРЫЕ ВОЗВРАЩАЛИСЬ ПАРАМИ ═══
//
// Придирки лечили правилом «correct собирается из сказанного игроком» — и
// той же правкой ломали учёт несказанного и подмену дня недели. Здесь
// проверяется, что теперь работают все три случая сразу.

// 1. Придирка не проходит и НЕ ОТНИМАЕТ БАЛЛ ЧЕРЕЗ ЛЕНТУ.
{
  const heardOk = "I wake up at seven every morning. After that I make coffee and read the news.";
  // Модель придралась: в её «правильном переводе» стоит get up вместо wake up.
  const nitpicked = "I get up at seven every morning. After that I make coffee and read the news.";
  const { errors, rejected } = reviewErrors(
    [{ said: "wake up", fix: "get up", kind: "word", why: "так говорят чаще" }],
    nitpicked,
    heardOk,
  );
  check("придирка не показывается", errors.length, 0);
  check("правка запомнена как отклонённая", rejected, [{ said: "wake up", fix: "get up" }]);
  check(
    "и откачена в переводе — лента не зачеркнёт верное слово",
    revertRejectedFixes(nitpicked, rejected),
    heardOk,
  );
}

// 2. Полфразы: перевод остаётся ЦЕЛЫМ, значит несказанное видно.
{
  const half = "I get up at seven every morning.";
  const whole = "I get up at seven every morning. Then I make coffee and read the news.";
  const { errors, rejected } = reviewErrors([], whole, half);
  check("ошибок нет — но и не должно быть", errors.length, 0);
  check("откатывать нечего", rejected.length, 0);
  check("несказанное осталось в переводе", revertRejectedFixes(whole, rejected), whole);
}

// 3. Sunday вместо Saturday: слово из образца обязано проходить как правка.
{
  const heardWrong = "My lessons are on Monday and Sunday.";
  const wholeCorrect = "My lessons are on Monday and Saturday.";
  const { errors } = reviewErrors(
    [{
      said: "Sunday",
      fix: "Saturday",
      kind: "meaning",
      why: "в задании суббота, а не воскресенье",
    }],
    wholeCorrect,
    heardWrong,
  );
  check("подмена дня остаётся ошибкой", errors.map((e) => e.text), ["Sunday"]);
}

// Пополнение списка доводов-придирок.
check("довод «так говорят» — не довод", nitpickReason("так говорят носители языка"), true);
check("довод «более употребительно» — не довод", nitpickReason("это более употребительно"), true);
check("довод «предпочтительнее» — не довод", nitpickReason("этот вариант предпочтительнее"), true);
check("довод про смысл остаётся доводом", nitpickReason("в задании суббота, а не воскресенье"), false);

// ═══ ПЛАШКА — ЭТО САМ КРАСНЫЙ ТЕКСТ, И К НЕМУ ПРИВЯЗАН ПЕРЕВОД ═══
//
// Настоящий раунд: «Мой телефон очень старый, поэтому он медленный. Я хочу
// новый в следующем году.» Игрок сказал «My phone is old, because he slow.
// I want new one in new year.» Границы кусков проводит дифф, переводы
// перечисляет модель — и сходятся эти два перечисления не всегда.
{
  const ribbonSpans = [
    { kind: "ok" as const, text: "My phone is " },
    { kind: "miss" as const, text: "very " },
    { kind: "bad" as const, text: "because he " },
    { kind: "miss" as const, text: "so it is " },
    { kind: "ok" as const, text: "slow. I want " },
    { kind: "miss" as const, text: "a " },
    { kind: "ok" as const, text: "new one " },
    { kind: "bad" as const, text: "in new " },
    { kind: "miss" as const, text: "next " },
    { kind: "ok" as const, text: "year." },
  ];
  const withMeanings = attachMeanings(ribbonSpans, [
    { text: "very", means: "очень" },
    { text: "so it is", means: "поэтому он" },
    { text: "a", means: "неопределённый артикль: один из многих" },
    { text: "next", means: "следующий" },
  ]);
  check(
    "перевод достался всем четырём несказанным кускам",
    withMeanings.filter((s) => s.kind === "miss").map((s) => s.means),
    ["очень", "поэтому он", "неопределённый артикль: один из многих", "следующий"],
  );
  check(
    "сказанному и зачёркнутому перевод не достаётся",
    withMeanings.filter((s) => s.kind !== "miss").every((s) => s.means === undefined),
    true,
  );

  // Модель перечислила куски иначе, чем провёл границы дифф.
  const looser = attachMeanings(ribbonSpans, [
    { text: "so it is slow", means: "поэтому он медленный" },
  ]);
  check(
    "кусок модели шире нашего — перевод всё равно находится",
    looser.find((s) => s.text.trim() === "so it is")?.means,
    "поэтому он медленный",
  );

  // Ничего похожего не прислали — кусок остаётся красным, но без нажатия.
  const none = attachMeanings(ribbonSpans, [{ text: "completely other", means: "другое" }]);
  check(
    "не нашлось — лучше без перевода, чем чужой",
    none.filter((s) => s.kind === "miss").every((s) => s.means === undefined),
    true,
  );
  check("пустой список ничего не ломает", attachMeanings(ribbonSpans, null).length, 10);
}

// ═══ РАЗБОР ОТВЕТА СВОЕЙ СХЕМЫ ПРОВАЙДЕРА ═══
//
// Форма ответа там вложенная и не одна: часть моделей кладёт текст списком
// частей, часть — строкой, часть — прямо в output.text. Разборщик, молча
// возвращающий null, неотличим от «модель ничего не сказала».
// ВОТ ГДЕ ЛЕЖИТ РАСШИФРОВКА У СВОЕЙ СХЕМЫ ПРОВАЙДЕРА. Документация особо
// оговаривает, что это НЕ output.choices — а смотрели мы именно туда.
check(
  "текст из output.output.sentence",
  nativeText('{"output":{"output":{"sentence":{"text":"I get up at seven."}}}}'),
  "I get up at seven.",
);
check(
  "несколько фраз склеиваются",
  nativeText('{"output":{"output":{"sentence":[{"text":"a"},{"text":"b"}]}}}'),
  "a b",
);
check(
  "текст списком частей",
  nativeText('{"output":{"choices":[{"message":{"content":[{"text":"I get up at seven."}]}}]}}'),
  "I get up at seven.",
);
check(
  "текст строкой",
  nativeText('{"output":{"choices":[{"message":{"content":"I get up at seven."}}]}}'),
  "I get up at seven.",
);
check("текст прямо в output", nativeText('{"output":{"text":"привет"}}'), "привет");
check("две части склеиваются", nativeText('{"output":{"choices":[{"message":{"content":[{"text":"a"},{"text":"b"}]}}]}}'), "a b");
check("не JSON — честный null", nativeText("<html>502</html>"), null);
check("JSON без текста — честный null", nativeText('{"output":{"choices":[]}}'), null);
check(
  "совместимый ответ распознавателя",
  chatText('{"choices":[{"message":{"content":"I get up at seven."}}]}'),
  "I get up at seven.",
);
check("совместимый ответ без текста — честный null", chatText('{"choices":[]}'), null);

// Семейство решает ВСЮ форму вызова: перепутанное семейство это не падение,
// а отказ провайдера на живой записи — баг, который видит только игрок.
check("омни зовётся как чат", asrFamily("qwen3-omni-flash"), "omni");
check("qwen3-asr — совместимый режим", asrFamily("qwen3-asr-flash"), "compat-asr");
check("qwen-audio-3.0 — своя схема", asrFamily("qwen-audio-3.0-asr-flash"), "native-asr");
check("fun-asr-flash — своя схема", asrFamily("fun-asr-flash-2026-06-15"), "native-asr");

console.log(failed === 0 ? "\nвсё сходится" : `\nрасхождений: ${failed}`);
if (failed > 0) Deno.exit(1);
