/**
 * Вход по нику ИЛИ по почте — одним полем.
 *
 * ЗАЧЕМ ОТДЕЛЬНАЯ ФУНКЦИЯ. Supabase умеет вход только по почте: чтобы
 * пустить по нику, надо сперва узнать, какая у этого ника почта. Сделать
 * это на клиенте означало бы открыть всем желающим превращение списка
 * ников (а он виден на Арене и в друзьях) в список почтовых адресов.
 *
 * ПОЭТОМУ ПОЧТА НАРУЖУ НЕ ВЫХОДИТ ВООБЩЕ. Функция сама спрашивает её у
 * базы служебным ключом, сама пробует пароль и отдаёт либо сессию, либо
 * отказ. По неверному нику и по неверному паролю ответ ОДИНАКОВЫЙ —
 * иначе перебором узнаётся, какие ники существуют.
 */

import { createClient } from "jsr:@supabase/supabase-js@2";

const FAILED = { error: "invalid_credentials" };

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (url === "" || serviceKey === "" || anonKey === "") {
    return json({ error: "not_configured" }, 500);
  }

  let login = "";
  let password = "";
  try {
    const body = await req.json();
    login = String(body?.login ?? "").trim();
    password = String(body?.password ?? "");
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  if (login === "" || password === "") return json(FAILED, 400);

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false },
  });
  const { data: email, error } = await admin.rpc("resolve_login_email", {
    p_login: login,
  });
  // Ника нет — отвечаем ровно тем же, чем ответим на неверный пароль.
  if (error || typeof email !== "string" || email === "") {
    return json(FAILED, 400);
  }

  const asUser = createClient(url, anonKey, {
    auth: { persistSession: false },
  });
  const signIn = await asUser.auth.signInWithPassword({ email, password });
  if (signIn.error || !signIn.data.session) return json(FAILED, 400);

  return json({
    access_token: signIn.data.session.access_token,
    refresh_token: signIn.data.session.refresh_token,
  });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
