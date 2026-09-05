/**
 * Один ключ на три сервиса Google — и как из него получается ключ для
 * каждого.
 *
 * ЗАЧЕМ ОБЩИЙ. Приложение ходит в три API Google: распознавание речи
 * (speech), синтез речи (texttospeech) и модель (generativelanguage). Ключ
 * у них может быть один, и держать три копии одного значения в секретах —
 * это три места, где однажды обновят два.
 *
 * ЗАЧЕМ ПРИ ЭТОМ ОСТАЛИСЬ ОТДЕЛЬНЫЕ ПЕРЕМЕННЫЕ. Потому что «может быть
 * один» — это не «обязан». Cloud-сервисы (speech, texttospeech) и AI
 * Studio (generativelanguage) выдают ключи по-разному, и один и тот же
 * ключ там принимают не всегда: ключ AI Studio Cloud-эндпоинты не узнаю́т
 * вовсе — в ответ приходит не «ключ не подошёл», а «этот API ключей не
 * принимает», как будто запрос пришёл без авторизации. Тогда ключей нужно
 * два, и переопределение на сервис — единственное, что позволяет это
 * пережить без правки кода.
 *
 * ПОРЯДОК: своя переменная сервиса, затем общая. Пусто — вызывающий сам
 * решает, что это значит: для распознавания это отказ, для озвучки —
 * просто выключенная кнопка.
 */
export type GoogleService = "asr" | "tts" | "llm";

const SPECIFIC: Record<GoogleService, string> = {
  asr: "ASR_API_KEY",
  tts: "TTS_API_KEY",
  llm: "LLM_API_KEY",
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
 * когда сервисов три и хватило бы одной общей переменной: человек заведёт
 * три секрета там, где нужен один.
 */
export function missingKeyMessage(service: GoogleService): string {
  return `нет ключа Google: задайте общий GOOGLE_API_KEY или ${SPECIFIC[service]} ` +
    `для этого сервиса (npx supabase secrets set GOOGLE_API_KEY=<ключ>)`;
}
