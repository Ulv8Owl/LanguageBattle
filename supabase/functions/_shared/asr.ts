/**
 * Распознавание речи — первый шаг двухшагового пути этой ветки.
 *
 * ЗАЧЕМ ДВА ШАГА, КОГДА ОДИН УЖЕ РАБОТАЕТ. Ради цены. Мультимодальной
 * модели на вход идёт аудио, и платим мы за аудио; здесь за аудио платит
 * только распознаватель — модель подешевле и заточенная ровно под одно
 * дело, — а судья получает текст, который стоит копейки. Ветка существует,
 * чтобы измерить, сколько на этом экономится и сколько при этом теряется.
 *
 * ЧТО ТЕРЯЕТСЯ, СКАЗАНО ЗДЕСЬ ЧЕСТНО. Всё, что слышно только в звуке:
 * произношение, ударение, проглоченное окончание, оборванное слово. Хуже
 * того, распознаватель ПРИГЛАЖИВАЕТ речь — расставляет знаки препинания,
 * пишет заглавные буквы, а иногда правит и грамматику, — и судья получает
 * ответ чище, чем он был. Поэтому «ошибок не найдено» на этом пути значит
 * «ошибок не осталось в тексте», а не «игрок сказал верно».
 *
 * ПРОТОКОЛ. Тот же OpenAI-совместимый /chat/completions, что и у судьи:
 * один адрес, один ключ, один разбор потока (см. requestQwen в review.ts).
 * Аудио уходит внутри сообщения как data-URL.
 */

import { base64, judgeBaseUrl, requestQwen } from "./review.ts";

/**
 * Модели распознавания, между которыми можно переключаться из настроек.
 *
 * ПОРЯДОК — ТОТ, В КОТОРОМ ИХ НАЗВАЛ ВЛАДЕЛЕЦ ПРОЕКТА, и первая работает
 * моделью по умолчанию. Список продублирован на клиенте (judge_models.dart)
 * намеренно: значение из профиля игрока — ввод снаружи, и проверять его
 * надо там, где им пользуются, иначе опечатка уедет в тело запроса.
 *
 * ВНИМАНИЕ НА `-filetrans`. У DashScope это отдельная, АСИНХРОННАЯ схема:
 * такие модели принимают не вложенное аудио, а ссылку на файл, и ответ
 * забирается вторым запросом. Здесь они вызываются тем же способом, что и
 * остальные, — то есть могут ответить ошибкой. Это выбор в пользу простоты:
 * сбой виден сразу, целиком, и лежит в отладке записи (`asr.error`), а
 * дописать вторую схему по настоящему тексту ошибки быстрее, чем угадывать
 * её заранее.
 */
export const ASR_MODELS = [
  "qwen-audio-3.0-asr-flash",
  "qwen-audio-3.0-asr-flash-filetrans",
  "fun-asr-mtl",
  "qwen3-asr-flash",
  "qwen3-asr-flash-filetrans",
  "fun-asr-flash-2026-06-15",
] as const;

export const DEFAULT_ASR_MODEL = ASR_MODELS[0];

/** Выбор игрока сильнее окружения; незнакомое значение — модель по умолчанию. */
export function asrModel(chosen?: string | null): string {
  const wanted = (chosen ?? "").trim();
  if ((ASR_MODELS as readonly string[]).includes(wanted)) return wanted;
  const fromEnv = Deno.env.get("ASR_MODEL");
  if (fromEnv && (ASR_MODELS as readonly string[]).includes(fromEnv)) return fromEnv;
  return DEFAULT_ASR_MODEL;
}

export interface AsrResult {
  /** Что распознано. Пустая строка — речи в записи не нашлось. */
  text: string;
  /** Сбой вызова. Пусто — вызов прошёл, даже если текста нет. */
  error?: string;
  debug: Record<string, unknown>;
}

/**
 * Расшифровывает запись. НИКОГДА НЕ БРОСАЕТ.
 *
 * Сбой распознавания — это `error`, а не исключение: воркер должен уметь
 * закрыть задачу честным «модель не ответила», иначе она повиснет в
 * 'processing', а игрок будет ждать результат, которого не будет.
 *
 * ═══ ФОРМА ВЫЗОВА ЗДЕСЬ НЕ ПРОИЗВОЛЬНАЯ. НЕ УПРОЩАТЬ. ═══
 *
 * Провайдер отвечает HTTP 400 «format is empty» на сообщение, в котором
 * лежит ОДНО АУДИО и больше ничего, — даже когда формат передан и он
 * заведомо непустой ("wav", других приложение не пишет). Это выяснилось
 * трижды и с трёх сторон:
 *
 *   * распознавание слало одно аудио вложением — отказ;
 *   * то же аудио ссылкой вместо вложения — тот же отказ слово в слово;
 *   * мультимодальная модель на соседней ветке работала месяц, сломалась
 *     ровно в тот день, когда из её сообщения убрали текстовую часть, и
 *     починилась, когда её вернули.
 *
 * Поэтому здесь ровно то же, что у работающего вызова: непустая системная
 * часть, звук вложением с явным форматом и короткая текстовая часть рядом.
 * Смысла в этом тексте нет — есть форма, которую провайдер принимает.
 *
 * ЯЗЫК НЕ ПОДСКАЗЫВАЕМ НАМЕРЕННО. Распознаватель определяет его сам, и это
 * не лень, а механика проверки «не тот язык»: сказав по-русски, игрок
 * получит русский текст, и судья это назовёт. Подскажи мы английский —
 * распознаватель услышал бы английский в чём угодно.
 */
export async function transcribe(req: {
  audio: Uint8Array;
  audioFormat: string;
  model?: string | null;
  budgetMs: number;
}): Promise<AsrResult> {
  const started = Date.now();
  const model = asrModel(req.model);
  const debug = (extra: Record<string, unknown> = {}) => ({
    provider: "asr",
    model,
    model_requested: (req.model ?? "").trim().length > 0 ? req.model : null,
    base_url: judgeBaseUrl(),
    audio_bytes: req.audio.byteLength,
    audio_format: req.audioFormat,
    ms: Date.now() - started,
    ...extra,
  });

  if (req.audio.byteLength === 0) {
    return { text: "", error: "запись пуста", debug: debug({ status: "failed" }) };
  }

  const answer = await requestQwen(
    "You are a speech transcriber. Write down exactly what is said and nothing else.",
    [
      audioPart(req.audio, req.audioFormat),
      { type: "text", text: "Transcribe this recording." },
    ],
    req.budgetMs,
    model,
    { audio: true, temperature: 0 },
  );

  if ("error" in answer) {
    // Модель, формат и размер — прямо в тексте ошибки: без них по скриншоту
    // не понять, чей это отказ и что мы вообще послали.
    const reason = `${model} (${req.audioFormat}, ${req.audio.byteLength} Б): ${answer.error}`;
    return { text: "", error: reason, debug: debug({ status: "failed", error: answer.error }) };
  }

  const text = cleanTranscript(answer.raw);
  return {
    text,
    debug: debug({
      status: text.length > 0 ? "ok" : "empty",
      // Сырой ответ обрезан: спорить о расшифровке можно только по нему, а
      // раздувать строку в базе незачем.
      raw: answer.raw.slice(0, 600),
    }),
  };
}

/** Аудио раунда в том виде, в каком его принимает провайдер. */
function audioPart(audio: Uint8Array, format: string): unknown {
  return {
    type: "input_audio",
    input_audio: {
      data: `data:audio/${format};base64,${base64(audio)}`,
      format,
    },
  };
}

/**
 * Убирает то, чем модели обрамляют расшифровку.
 *
 * Часть из них отвечает не голым текстом, а вежливо: кавычки вокруг, иногда
 * markdown-заборчик, иногда «Transcription:» впереди. Всё это попало бы в
 * ленту разбора как слова игрока и зачёркивалось бы красным.
 */
function cleanTranscript(raw: string): string {
  let text = raw.trim();
  const fence = text.match(/^```[a-z]*\n([\s\S]*?)\n?```$/i);
  if (fence) text = fence[1].trim();
  text = text.replace(/^(transcription|transcript|text)\s*[:：]\s*/i, "").trim();
  if (text.length > 1 && /^["'«].*["'»]$/s.test(text)) text = text.slice(1, -1).trim();
  return text;
}
