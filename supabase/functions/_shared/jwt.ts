/**
 * Разбор JWT, которым Supabase представляет вызывающего.
 *
 * ПОДПИСЬ ЗДЕСЬ НЕ ПРОВЕРЯЕТСЯ, и это не упущение: функции деплоятся с
 * verify_jwt (значение по умолчанию), то есть платформа уже отвергла
 * запрос с неверной подписью до того, как код получил управление.
 * Проверять её второй раз означало бы держать в функции ключ подписи ради
 * работы, которая уже сделана.
 *
 * Отсюда и граница ответственности: платформа отвечает за подлинность
 * токена, эта функция — только за то, ЧТО в нём написано.
 */
export interface JwtClaims {
  /** service_role, authenticated, anon — как проставил Supabase. */
  role: string | null;
  /** Идентификатор пользователя. У service_role его нет. */
  sub: string | null;
}

/** Токен из заголовка Authorization, без префикса Bearer. */
export function bearerToken(req: Request): string {
  return (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
}

export function jwtClaims(token: string): JwtClaims {
  const parts = token.split(".");
  if (parts.length !== 3) return { role: null, sub: null };
  try {
    const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload = JSON.parse(atob(padded + "=".repeat((4 - (padded.length % 4)) % 4)));
    return {
      role: typeof payload?.role === "string" ? payload.role : null,
      sub: typeof payload?.sub === "string" ? payload.sub : null,
    };
  } catch {
    return { role: null, sub: null };
  }
}
