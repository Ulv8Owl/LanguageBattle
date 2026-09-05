/**
 * Один ключ Google на распознавание и синтез речи.
 *
 * ЗАЧЕМ ОБЩИЙ. Оба сервиса (speech и texttospeech) живут в Google Cloud и
 * ходят под одним Cloud-ключом. Держать две копии одного значения в
 * секретах — это два места, где однажды обновят одно.
 *
 * ЗАЧЕМ ПРИ ЭТОМ ОСТАЛИСЬ ОТДЕЛЬНЫЕ ПЕРЕМЕННЫЕ. Потому что «может быть
 * один» — это не «обязан»: ограничения ключа задаются списком API, и
 * ключ, которому разрешили только синтез, распознавание не обслужит.
 *
 * МОДЕЛИ ЗДЕСЬ НЕТ, и это важно. Ключ модели живёт в llmChat.ts
 * (llmKey), потому что провайдер модели не обязан быть Google вовсе — по
 * умолчанию он и не Google. Отдать сюда «ключ LLM» значило бы при
 * стороннем провайдере отправить чужому получателю рабочий Cloud-ключ от
 * распознавания и синтеза.
 *
 * ПОРЯДОК: своя переменная сервиса, затем общая. Пусто — вызывающий сам
 * решает, что это значит: для распознавания это отказ, для озвучки —
 * просто выключенная кнопка.
 */
export type GoogleService = "asr" | "tts";

const SPECIFIC: Record<GoogleService, string> = {
  asr: "ASR_API_KEY",
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
