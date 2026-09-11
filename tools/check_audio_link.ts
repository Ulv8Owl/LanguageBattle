// Ссылка на запись для распознавания: кончается расширением, живёт недолго,
// подделке не поддаётся.
//
// Провайдер определяет формат аудио ПО РАСШИРЕНИЮ В ССЫЛКЕ. Подписанная
// ссылка Supabase кончается на `.wav?token=…`, и он её не разбирает: одна
// модель отвечает «format is empty», другая — «url error». Поэтому токен
// лежит в ПУТИ, а не в запросе. Здесь проверяется, что он там и остаётся —
// и что ничего, кроме одного файла и ненадолго, он не открывает.
//
// Запуск: deno run tools/check_audio_link.ts
import { audioUrlFor, mintAudioToken, readAudioToken } from "../supabase/functions/_shared/audioLink.ts";

let failed = 0;
function check(name: string, actual: unknown, expected: unknown) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed++;
  console.log(`${ok ? "OK  " : "FAIL"} ${name}: ${JSON.stringify(actual)}`);
}

async function main() {
  const secret = "service-role-key-для-проверки";
  const path = "training/2f1c/9ab4/user_1.wav";

  const url = await audioUrlFor(path, "https://proj.supabase.co/", secret);
  check("ссылка кончается расширением файла", url.endsWith(".wav"), true);
  check("в ссылке нет запроса — только путь", url.includes("?"), false);
  check("ведёт на свою функцию", url.includes("/functions/v1/asr-audio/"), true);

  const token = url.split("/").pop()!.replace(/\.wav$/, "");
  check("путь читается обратно", await readAudioToken(token, secret), path);
  check("чужим ключом не читается", await readAudioToken(token, "другой ключ"), null);
  check("подделанная подпись не читается", await readAudioToken(token.slice(0, -2) + "xx", secret), null);
  check("мусор вместо токена", await readAudioToken("не-токен", secret), null);
  check("пустой токен", await readAudioToken("", secret), null);

  // Токен на ЧУЖОЙ файл своим ключом подписать можно — но это другой токен, и
  // прежний от этого читаться иначе не станет.
  const other = await mintAudioToken("training/чужая/запись.wav", secret);
  check("свой токен — свой путь", await readAudioToken(other, secret), "training/чужая/запись.wav");
  check("токены разные", other === token, false);

  // Срок: подписываем вручную просроченный payload тем же ключом.
  const expired = await (async () => {
    const body = btoa(`${path}|1`).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
    const b64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    return `${body}.${b64}`;
  })();
  check("истёкший токен не читается", await readAudioToken(expired, secret), null);

    console.log(failed === 0 ? "\nвсё сходится" : `\nрасхождений: ${failed}`);
  if (failed > 0) Deno.exit(1);
}

main();
