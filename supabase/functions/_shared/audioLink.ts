/**
 * Ссылка на запись, КОНЧАЮЩАЯСЯ НА .wav И БЕЗ ХВОСТА.
 *
 * ЗАЧЕМ ЭТО ВООБЩЕ ЕСТЬ. Провайдер распознавания определяет формат аудио по
 * расширению в ссылке и больше ниоткуда. Подписанная ссылка Supabase
 * кончается на `.wav?token=eyJ…`, и он её не разбирает: одна модель
 * отвечает «format is empty», другая — «url error, please check url!».
 * Выяснилось это не из документации, а из трёх разных отказов подряд.
 *
 * ПОЧЕМУ НЕ ПУБЛИЧНЫЙ БАКЕТ. Он решал бы ту же задачу одной строкой, но
 * ценой того, что голосовые записи становятся публично читаемыми — пусть и
 * под случайным именем и на секунды. Голос игрока для этого слишком личная
 * вещь, чтобы разменивать её на удобство.
 *
 * ЧТО ВМЕСТО. Токен на ОДИН файл и на несколько минут, подписанный
 * серверным ключом, который наружу не попадает никогда. Токен лежит В ПУТИ,
 * а не в запросе, — поэтому ссылка и кончается на `.wav`:
 *
 *     https://<проект>.supabase.co/functions/v1/asr-audio/<токен>.wav
 *
 * Отдаёт файл функция `asr-audio`. Сам бакет остаётся закрытым, и ничего,
 * кроме одной записи и ненадолго, такой токен не открывает.
 */

/** Сколько живёт токен. Дольше любого разбора и много меньше самой записи. */
const TOKEN_TTL_SECONDS = 600;

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * Отдаёт именно ArrayBuffer, а не Uint8Array: WebCrypto ждёт BufferSource, а
 * типы Uint8Array в свежем TypeScript параметризованы буфером и на эту роль
 * без приведения не подходят.
 */
function fromBase64url(text: string): ArrayBuffer {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out.buffer;
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

/**
 * Подписывает путь к записи. Возвращает токен для пути ссылки.
 *
 * Подписываем ИМЕННО ПУТЬ И СРОК ВМЕСТЕ: подпись только пути позволила бы
 * держать ссылку вечно, подпись только срока — подставить чужой файл.
 */
export async function mintAudioToken(storagePath: string, secret: string): Promise<string> {
  const exp = Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS;
  const payload = `${storagePath}|${exp}`;
  const body = base64url(new TextEncoder().encode(payload));
  const sig = await crypto.subtle.sign(
    "HMAC",
    await hmacKey(secret),
    new TextEncoder().encode(body),
  );
  return `${body}.${base64url(new Uint8Array(sig))}`;
}

/**
 * Проверяет токен. Возвращает путь к записи или null.
 *
 * NULL НА ЛЮБУЮ БЕДУ, без подробностей наружу: истёк, подделан, испорчен —
 * для того, кто его прислал, это должно выглядеть одинаково.
 */
export async function readAudioToken(token: string, secret: string): Promise<string | null> {
  const [body, sig] = token.split(".");
  if (!body || !sig) return null;
  try {
    const ok = await crypto.subtle.verify(
      "HMAC",
      await hmacKey(secret),
      fromBase64url(sig),
      new TextEncoder().encode(body),
    );
    if (!ok) return null;
    const payload = new TextDecoder().decode(fromBase64url(body));
    const cut = payload.lastIndexOf("|");
    if (cut < 0) return null;
    const path = payload.slice(0, cut);
    const exp = Number(payload.slice(cut + 1));
    if (!Number.isFinite(exp) || exp < Math.floor(Date.now() / 1000)) return null;
    return path.length > 0 ? path : null;
  } catch {
    return null;
  }
}

/** Готовая ссылка для провайдера: путь кончается расширением файла. */
export async function audioUrlFor(
  storagePath: string,
  supabaseUrl: string,
  secret: string,
): Promise<string> {
  const token = await mintAudioToken(storagePath, secret);
  const ext = storagePath.split(".").pop()?.toLowerCase() ?? "wav";
  return `${supabaseUrl.replace(/\/$/, "")}/functions/v1/asr-audio/${token}.${ext}`;
}
