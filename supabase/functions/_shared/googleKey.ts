/**
 * Ключ Google для синтеза речи.
 *
 * ОСТАЛСЯ ОДИН СЕРВИС. Раньше здесь же резолвился ключ распознавания —
 * распознавание удалено, речь разбирает мультимодальная модель под своим
 * ключом (OMNI_API_KEY). Из общей развилки уцелела только озвучка.
 *
 * ЗАЧЕМ ТОГДА ДВЕ ПЕРЕМЕННЫЕ. GOOGLE_API_KEY остаётся общим именем для
 * Cloud-ключа, TTS_API_KEY — переопределением на случай, когда ключу
 * разрешён более узкий список API. Порядок: своя переменная, затем общая.
 * Пусто — озвучка просто не работает, кнопка гаснет; играть это не мешает.
 */
export type GoogleService = "tts";

const SPECIFIC: Record<GoogleService, string> = {
  tts: "TTS_API_KEY",
};

/** Ключ для сервиса или null, если не задан ни свой, ни общий. */
export function googleKey(service: GoogleService): string | null {
  const own = Deno.env.get(SPECIFIC[service]);
  if (own && own.length > 0) return own;
  const shared = Deno.env.get("GOOGLE_API_KEY");
  return shared && shared.length > 0 ? shared : null;
}

/** Откуда взялся ключ — для отладочной панели и config-check. */
export function googleKeySource(service: GoogleService): string {
  const own = Deno.env.get(SPECIFIC[service]);
  if (own && own.length > 0) return SPECIFIC[service];
  return Deno.env.get("GOOGLE_API_KEY") ? "GOOGLE_API_KEY" : "(не задан)";
}

/**
 * Как назвать отсутствующий ключ в сообщении об ошибке.
 *
 * Отдельная функция, потому что подсказка «задай ASR_API_KEY» неверна,
 * когда хватило бы одной общей переменной: человек заведёт два секрета
 * там, где нужен один.
 */
export function missingKeyMessage(service: GoogleService): string {
  return `нет ключа Google: задайте общий GOOGLE_API_KEY или ${SPECIFIC[service]} ` +
    `для этого сервиса (npx supabase secrets set GOOGLE_API_KEY=<ключ>)`;
}
