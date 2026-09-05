// Озвучка текста для игрока: «послушать, как это должно звучать».
//
// ПОЧЕМУ ЭТО СЕРВЕР, А НЕ ТЕЛЕФОН. Ключ Google лежит в секретах функции и
// в приложение не попадает никогда. Синтез на устройстве (системный TTS)
// был бы бесплатным, но голос и качество там зависят от того, что
// установлено у конкретного игрока: на одном телефоне английский звучит
// прилично, на другом — робот, а на третьем нужного языка нет вовсе.
// Образец произношения обязан быть одинаковым для всех, иначе он не
// образец.
//
// ЯЗЫК БЕРЁТСЯ ИЗ ПАРЫ ИГРОКА, а не из запроса. Клиент присылает, на каком
// языке он ждёт озвучку, но последнее слово за базой: сверяем с активной
// парой (user_languages, role = learning). Иначе достаточно было бы
// подменить один параметр, чтобы читать испанский текст английским
// голосом — и это не абстрактная дыра, а ровно тот случай, когда игрок
// заучит неверное произношение.
//
// ЭНЕРГИЮ НЕ ТРАТИТ. Энергия платит за ответы, которые двигают раунд:
// распознавание и разбор. Прослушивание — справка, и брать за неё плату
// значило бы наказывать за попытку разобраться, чего в этой игре нигде
// больше нет (та же логика, что у подсказок: множитель режет монеты, но
// не опыт).

import { createClient } from "jsr:@supabase/supabase-js@2";

import { bearerToken, jwtClaims } from "../_shared/jwt.ts";
import { MAX_TTS_CHARS, SynthesisError, synthesizeSpeech } from "../_shared/tts.ts";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "нужен POST" }, 405);
  }

  const claims = jwtClaims(bearerToken(req));
  // service_role пускаем ради ручной проверки с сервера; игроку же нужен
  // его собственный токен — по нему мы и узнаём, чья это пара языков.
  if (claims.role !== "authenticated" && claims.role !== "service_role") {
    return json({ error: "нужен токен игрока" }, 401);
  }

  let payload: { text?: unknown; languageCode?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "тело запроса не разобрано как JSON" }, 400);
  }

  const text = typeof payload.text === "string" ? payload.text : "";
  const requested = typeof payload.languageCode === "string" ? payload.languageCode : "";
  if (text.trim().length === 0) {
    return json({ error: "нечего озвучивать" }, 400);
  }
  if (text.length > MAX_TTS_CHARS) {
    return json({ error: `текст длиннее ${MAX_TTS_CHARS} символов` }, 400);
  }
  if (requested.length === 0) {
    return json({ error: "не указан язык" }, 400);
  }

  // Сверка с парой игрока. service_role такой пары не имеет — его запрос
  // проходит как есть, потому что это ручная проверка, а не игра.
  if (claims.role === "authenticated") {
    if (!claims.sub) return json({ error: "в токене нет пользователя" }, 401);
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data, error } = await supabase
      .from("user_languages")
      .select("language_code")
      .eq("user_id", claims.sub)
      .eq("role", "learning")
      .eq("is_active", true)
      .limit(1)
      .maybeSingle();
    if (error) {
      console.error("synthesize-speech: не удалось прочитать пару", error);
      return json({ error: "не удалось проверить языковую пару" }, 500);
    }
    const learning = data?.language_code;
    if (!learning) {
      return json({ error: "у игрока нет активной изучаемой пары" }, 409);
    }
    if (learning !== requested) {
      // Не молча подменяем на верный язык, а отказываем: расхождение
      // означает, что клиент и база разошлись во мнении о том, что игрок
      // учит, и озвучить «как-нибудь» здесь хуже, чем не озвучить.
      return json(
        { error: `язык не совпадает с парой игрока: просили ${requested}, учит ${learning}` },
        409,
      );
    }
  }

  try {
    const result = await synthesizeSpeech(text, requested);
    return json({ audioContent: result.audioContent, debug: result.debug });
  } catch (e) {
    if (e instanceof SynthesisError) {
      console.error("synthesize-speech:", e.message);
      return json({ error: e.message }, e.status);
    }
    console.error("synthesize-speech: неожиданный сбой", e);
    return json({ error: `сбой синтеза: ${e}` }, 500);
  }
});
