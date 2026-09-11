/**
 * Отдаёт запись по ссылке, которая кончается на .wav — и только по токену.
 *
 * ЗАЧЕМ. Провайдер распознавания определяет формат аудио по расширению в
 * ссылке. Подписанная ссылка Supabase кончается на `.wav?token=…`, и он её
 * не разбирает (см. _shared/audioLink.ts). Здесь токен лежит В ПУТИ, и
 * ссылка кончается расширением.
 *
 * ДЕПЛОИТСЯ С --no-verify-jwt, И ЭТО ОБЯЗАТЕЛЬНО: запрос приходит от
 * провайдера, у которого нашего токена Supabase нет и быть не может. Но
 * «без проверки JWT» не значит «без проверки»: без действующей подписи на
 * КОНКРЕТНЫЙ путь функция не отдаёт ничего.
 *
 * ЧТО ОНА НЕ ДЕЛАЕТ. Не листает бакет, не принимает путь из запроса, не
 * отдаёт ничего, кроме одного файла, на который выписан токен, и не живёт
 * дольше срока в токене. Бакет остаётся закрытым.
 */

import { createClient } from "jsr:@supabase/supabase-js@2";
import { readAudioToken } from "../_shared/audioLink.ts";

const TYPES: Record<string, string> = {
  wav: "audio/wav",
  mp3: "audio/mpeg",
  m4a: "audio/mp4",
  aac: "audio/aac",
  ogg: "audio/ogg",
  flac: "audio/flac",
  webm: "audio/webm",
};

Deno.serve(async (req) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("method not allowed", { status: 405 });
  }

  const secret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (secret.length === 0) return new Response("not configured", { status: 500 });

  // Последний кусок пути: «<токен>.<расширение>».
  const last = new URL(req.url).pathname.split("/").filter((p) => p.length > 0).pop() ?? "";
  const dot = last.lastIndexOf(".");
  const token = dot > 0 ? last.slice(0, dot) : last;
  const ext = dot > 0 ? last.slice(dot + 1).toLowerCase() : "wav";

  const path = await readAudioToken(token, secret);
  // ОДИН И ТОТ ЖЕ ОТВЕТ на истёкший, подделанный и испорченный токен: по
  // разнице между ними можно было бы подбирать.
  if (path === null) return new Response("not found", { status: 404 });

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    secret,
    { auth: { persistSession: false } },
  );
  const { data, error } = await supabase.storage.from("voice-recordings").download(path);
  if (error || !data) return new Response("not found", { status: 404 });

  const bytes = new Uint8Array(await data.arrayBuffer());
  const headers = {
    "Content-Type": TYPES[ext] ?? "application/octet-stream",
    "Content-Length": String(bytes.byteLength),
    // Ссылка одноразовая по смыслу — кэшировать её незачем и негде.
    "Cache-Control": "no-store",
  };
  return new Response(req.method === "HEAD" ? null : bytes, { status: 200, headers });
});
