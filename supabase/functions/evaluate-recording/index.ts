// Воркер очереди evaluation_jobs (раздел 9.7). Вызывается триггером на
// INSERT в evaluation_jobs (см. supabase/migrations/0004_ai_pipeline_trigger.sql).
// Клиент никогда не ждёт эту функцию синхронно — он подписан на
// round_scores/training_rounds/evaluation_jobs через Realtime и узнаёт о
// результате, когда воркер его допишет.
//
// Один и тот же путь обслуживает все три режима: Состязание, Дуэль и
// Одиночную Игру (в соло тоже начисляются валюта и опыт, поэтому оценивать
// на клиенте нельзя — раздел 2.2).
//
// Воркер делает ДВА шага подряд:
//   1) распознаёт речь по загруженному аудио (transcribeAudio.ts) — раньше
//      это делал сам телефон средствами ОС, но одновременный захват
//      микрофона записью и распознавателем на Android не работает, и
//      транскрипт всегда приходил пустым;
//   2) отдаёт транскрипт LLM-судье (evaluateGrammar.ts).
//
// Балл берётся НАПРЯМУЮ из ответа LLM (раздел 9.4, MVP-версия): без
// нормирующей формулы, без фильтра по категории ошибок и без сопоставления
// с confidence ASR. Все три пункта осознанно отложены — см.
// deferred_suggestions.md, не добавлять их сюда без отдельного запроса.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import {
  type CefrLevel,
  evaluateGrammar,
  type JudgeVerbosity,
  NEUTRAL_SCORE,
} from "../_shared/evaluateGrammar.ts";
import { transcribeAudio } from "../_shared/transcribeAudio.ts";

/**
 * Лига говорящего приравнена к уровню CEFR (см. supabase/migrations/0010 —
 * те же границы ELO, что и league_index_for_elo/cefr_level_for_elo там,
 * продублировано здесь, потому что Edge Function не может импортировать
 * SQL). Если меняете пороги — меняйте в обоих местах.
 */
function cefrLevelForElo(elo: number): CefrLevel {
  if (elo < 1200) return "A1";
  if (elo < 1500) return "A2";
  if (elo < 1800) return "B1";
  if (elo < 2100) return "B2";
  if (elo < 2400) return "C1";
  return "C2";
}

/** Балл за тишину: ASR отработал, но говорить было не о чем. */
const EMPTY_TRANSCRIPT_SCORE = 1;

/** Статусы распознавания — те же значения, что в CHECK у voice_recordings (миграция 0013). */
type TranscriptStatus = "pending" | "ok" | "empty" | "failed";

/** Статусы работы судьи — CHECK у voice_recordings (миграция 0014). */
type JudgeStatus = "pending" | "ok" | "degraded" | "skipped";

/** Поля voice_recordings, которыми пользуется воркер. */
interface VoiceRecordingRow {
  id: string;
  user_id: string;
  round_id: string | null;
  training_round_id: string | null;
  recording_slot: string;
  language_code: string | null;
  audio_storage_path: string;
  transcript: string | null;
  transcript_status: TranscriptStatus | null;
  attempt_number: number | null;
  created_at: string;
}

/**
 * Продлевает жизнь воркера после отправки ответа. Есть в рантайме Supabase
 * Edge Functions; объявлено здесь, потому что в типах Deno этого нет.
 */
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

Deno.serve(async (req: Request) => {
  // Отвечаем СРАЗУ, а работу доделываем в фоне.
  //
  // Вызывающая сторона — триггер БД через pg_net, у которого таймаут на
  // запрос (по умолчанию всего 5 секунд, см. миграцию 0015). Пока воркер
  // отвечал за доли секунды, это было незаметно; теперь он ждёт
  // распознавание речи и подробный разбор LLM — десятки секунд. Когда
  // вызывающая сторона отваливается по таймауту, платформа вправе убить
  // изолят на середине: задача остаётся в 'processing' навсегда, а игрок
  // смотрит на бесконечный спиннер «Разбираю попытку».
  //
  // Ответ здесь — это подтверждение приёма задачи, а НЕ её результат:
  // результат клиент и так получает через Realtime, синхронно его никто не
  // ждёт (раздел 9.8).
  // Тело читаем ДО ответа: после него поток запроса уже может быть закрыт.
  let jobId: string | undefined;
  try {
    jobId = (await req.json())?.job_id;
  } catch (e) {
    console.error("evaluate-recording: не разобрал тело запроса", e);
  }
  if (!jobId) {
    return new Response(JSON.stringify({ error: "job_id is required" }), { status: 400 });
  }

  const started = processJob(jobId);
  if (typeof EdgeRuntime !== "undefined") {
    EdgeRuntime.waitUntil(started);
  } else {
    // Локальный запуск без рантайма Supabase — там ждём обычным способом,
    // иначе задача оборвётся вместе с ответом.
    await started;
  }

  return new Response(JSON.stringify({ accepted: true, job_id: jobId }), {
    status: 202,
    headers: { "Content-Type": "application/json" },
  });
});

async function processJob(job_id: string): Promise<void> {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    const { data: job, error: jobErr } = await supabase
      .from("evaluation_jobs")
      .select("*")
      .eq("id", job_id)
      .single();
    if (jobErr || !job) {
      // "job not found" раньше маскировал ЛЮБУЮ ошибку запроса (права
      // доступа, формат id и т.п.) под одинаковый неинформативный ответ —
      // логируем настоящую причину, чтобы не гадать вслепую по логам.
      console.error("evaluate-recording: job lookup failed", { job_id, jobErr });
      return;
    }
    if (job.status !== "pending") {
      // Уже обрабатывается/обработана — не задваиваем работу.
      return;
    }

    await supabase.from("evaluation_jobs").update({ status: "processing" }).eq("id", job_id);

    const { data: recordingRow, error: recErr } = await supabase
      .from("voice_recordings")
      .select("*")
      .eq("id", job.voice_recording_id)
      .single();
    if (recErr || !recordingRow) {
      console.error("evaluate-recording: recording lookup failed", {
        voiceRecordingId: job.voice_recording_id,
        recErr,
      });
      await supabase.from("evaluation_jobs").update({ status: "failed" }).eq("id", job_id);
      return;
    }
    const recording = recordingRow as VoiceRecordingRow;

    // Голосовое на родном языке в Дуэли — только для прослушки соперником,
    // не оценивается (см. раздел 2.4), поэтому и распознавать его незачем.
    if (recording.recording_slot === "native") {
      await markDone(supabase, job_id);
      return;
    }

    const targetLanguage = recording.language_code ?? "en";

    // Фраза раунда на изучаемом языке — то, что игрок должен был сказать.
    // Нужна дважды: подсказкой распознавателю и эталоном судье, поэтому
    // читается один раз здесь.
    const expectedPhrase = await roundPhrase(supabase, recording);

    // Шаг 1 — распознавание речи.
    const { transcript, status, debug: asrDebug } = await resolveTranscript(
      supabase,
      recording,
      targetLanguage,
      expectedPhrase,
    );
    // Диагностика пайплайна для отладочной панели в игре (миграция 0016).
    const pipelineDebug: Record<string, unknown> = { asr: asrDebug };

    // Номер попытки в соло нужен ДО вызова судьи: на второй попытке
    // текстовые объяснения не показываются, а значит и генерировать их не
    // надо — это основная часть времени ответа.
    const attempt = recording.training_round_id
      ? await trainingAttemptNumber(supabase, recording)
      : { attempt: 1, source: "PvP" };
    const attemptNumber = attempt.attempt;

    // Шаг 2 — оценка. Три исхода распознавания дают три разных балла, и
    // путать их нельзя: за нашу поломку игрок не должен получать 1.
    let score: number;
    let errors: { offset: number; length: number; message: string; replacement: string; category: string }[] = [];
    let feedback: string;

    let judgeStatus: JudgeStatus;
    let correctedText = "";
    let cleanedText = "";

    if (status === "failed") {
      score = NEUTRAL_SCORE;
      feedback = "Не удалось распознать речь — балл выставлен нейтральным.";
      judgeStatus = "skipped";
      pipelineDebug.judge = { status: "skipped", reason: "речь не распознана — судью не звали" };
    } else if (status === "empty") {
      score = EMPTY_TRANSCRIPT_SCORE;
      feedback = "Не удалось разобрать речь — попробуй сказать чётче и ближе к микрофону.";
      judgeStatus = "skipped";
      pipelineDebug.judge = { status: "skipped", reason: "записана тишина — судью не звали" };
    } else {
      // Лига говорящего на этом языке -> уровень CEFR (скрытая механика:
      // приравнивание лиг к A1-C2) — ограничивает только сложность текста
      // объяснений LLM, не саму оценку. Нет строки/ELO — считаем новичком
      // (1000 ELO по умолчанию, как и везде в проекте).
      const { data: speakerLanguage } = await supabase
        .from("user_languages")
        .select("elo")
        .eq("user_id", recording.user_id)
        .eq("language_code", targetLanguage)
        .eq("role", "learning")
        .maybeSingle();
      const level = cefrLevelForElo(speakerLanguage?.elo ?? 1000);

      const { data: speaker } = await supabase
        .from("users")
        .select("native_language")
        .eq("id", recording.user_id)
        .single();
      const nativeLanguage = speaker?.native_language ?? "en";

      // Первая попытка Одиночной Игры просит подробный разбор (раздел 2.2:
      // игрок должен понять, что исправить перед второй попыткой). Вторая
      // показывает только подсветку правки — объяснения там не выводятся,
      // поэтому не запрашиваются. PvP получает короткую пометку в ленте боя.
      // Балл и исправленный текст считаются одинаково во всех режимах.
      const verbosity: JudgeVerbosity = recording.training_round_id == null
        ? "brief"
        : attemptNumber >= 2
        ? "marksOnly"
        : "detailed";
      // Номер попытки и выбранный режим — в отладку: по экрану невозможно
      // отличить «судью попросили объяснять» от «попытку сочли первой».
      pipelineDebug.round = {
        attempt: attemptNumber,
        attempt_source: attempt.source,
        verbosity,
      };
      const result = await evaluateGrammar(
        transcript,
        targetLanguage,
        nativeLanguage,
        verbosity,
        level,
        expectedPhrase,
      );

      score = result.score;
      errors = result.errors;
      judgeStatus = result.degraded ? "degraded" : "ok";
      pipelineDebug.judge = result.debug;
      correctedText = result.corrected;
      cleanedText = result.cleaned;
      feedback = result.degraded
        ? "Не удалось получить разбор от ИИ — балл выставлен нейтральным."
        : errors.length === 0
        ? "Отлично, ошибок не найдено!"
        : errors.map((e) => e.message).slice(0, 3).join(" ");

      if (result.degraded) {
        console.error("evaluate-recording: судья деградировал", {
          recordingId: recording.id,
          reason: result.failureReason,
        });
      }
    }

    await supabase
      .from("voice_recordings")
      .update({
        judge_status: judgeStatus,
        pipeline_debug: pipelineDebug,
        corrected_text: correctedText,
        cleaned_text: cleanedText,
      })
      .eq("id", recording.id);

    if (errors.length > 0) {
      await supabase.from("grammar_errors").insert(
        errors.map((e) => ({
          voice_recording_id: recording.id,
          offset_start: e.offset,
          length: e.length,
          message: e.message,
          replacement: e.replacement,
          category: e.category,
        })),
      );
    }

    if (recording.round_id) {
      // PvP: балл за раунд.
      await supabase.from("round_scores").upsert(
        { round_id: recording.round_id, user_id: recording.user_id, score, ai_feedback: feedback },
        { onConflict: "round_id,user_id" },
      );
    } else if (recording.training_round_id) {
      // Одиночная Игра (раздел 2.2): попытка №1 даёт только разбор ошибок,
      // финальный балл ставится по попытке №2. Попытки различаются по
      // порядку created_at внутри одного training_round — как в схеме
      // (раздел 4), без отдельного поля attempt.
      if (attemptNumber >= 2) {
        await supabase
          .from("training_rounds")
          .update({ final_score: score })
          .eq("id", recording.training_round_id);
      }
    }

    await markDone(supabase, job_id);
    console.log("evaluate-recording: готово", { job_id, score, transcript_status: status, judge_status: judgeStatus });
  } catch (e) {
    // Задача ОБЯЗАНА получить конечный статус в любом случае: клиент ждёт
    // 'done'/'failed' через Realtime, и оставленный 'processing' — это
    // бесконечный спиннер у игрока.
    console.error("evaluate-recording failed:", e);
    await supabase.from("evaluation_jobs").update({ status: "failed" }).eq("id", job_id);
  }
}

/**
 * Возвращает транскрипт записи, распознавая аудио, если это ещё не сделано,
 * и сохраняя результат обратно в voice_recordings — чтобы повторный запуск
 * задачи по той же записи не гонял ASR второй раз, а клиент мог показать
 * игроку, что именно услышал распознаватель.
 */
async function resolveTranscript(
  supabase: SupabaseClient,
  recording: VoiceRecordingRow,
  targetLanguage: string,
  expectedPhrase: string,
): Promise<{ transcript: string; status: TranscriptStatus; debug: Record<string, unknown> }> {
  const existing = (recording.transcript ?? "").trim();
  if (existing.length > 0) {
    if (recording.transcript_status !== "ok") {
      await saveTranscript(supabase, recording.id, existing, [], "ok");
    }
    return { transcript: existing, status: "ok", debug: { status: "ok", transcript: existing, cached: true } };
  }
  if (recording.transcript_status === "empty" || recording.transcript_status === "failed") {
    // Уже пробовали и не получилось — не тратим квоту провайдера повторно.
    return {
      transcript: "",
      status: recording.transcript_status,
      debug: { status: recording.transcript_status, cached: true },
    };
  }

  const { data: file, error: downloadErr } = await supabase.storage
    .from("voice-recordings")
    .download(recording.audio_storage_path);
  if (downloadErr || !file) {
    console.error("evaluate-recording: audio download failed", {
      path: recording.audio_storage_path,
      downloadErr,
    });
    await saveTranscript(supabase, recording.id, "", [], "failed");
    return {
      transcript: "",
      status: "failed",
      debug: { status: "failed", error: `не удалось скачать аудио: ${downloadErr?.message ?? downloadErr}` },
    };
  }

  const audio = new Uint8Array(await file.arrayBuffer());
  // Фраза раунда — это ровно то, что игрок сейчас пытается повторить.
  // Отдаём её распознавателю подсказкой: он всё так же слышит настоящую
  // речь со всеми ошибками, но перестаёт угадывать слова из всего языка
  // сразу и заметно реже подставляет непохожие.
  const asr = await transcribeAudio(audio, targetLanguage, hintPhrases(expectedPhrase));

  const status: TranscriptStatus = asr.degraded ? "failed" : asr.transcript.length > 0 ? "ok" : "empty";
  await saveTranscript(supabase, recording.id, asr.transcript, asr.words, status);
  return { transcript: asr.transcript, status, debug: asr.debug };
}

/**
 * Какая это попытка в раунде.
 *
 * Основной источник — attempt_number, который проставляет клиент (миграция
 * 0019): он этот номер знает точно. Подсчёт строк остался только для
 * записей от прежних сборок, где столбца ещё нет.
 *
 * Раньше подсчёт был единственным источником и его ошибка не проверялась:
 * `count ?? 1` превращал любой сбой запроса во «вторую попытку — это
 * первая», а на экране это выглядело как исправная работа. Теперь неудача
 * возвращается наружу и попадает в отладочную панель.
 */
async function trainingAttemptNumber(
  supabase: SupabaseClient,
  recording: VoiceRecordingRow,
): Promise<{ attempt: number; source: string }> {
  if (recording.attempt_number != null) {
    return { attempt: recording.attempt_number, source: "клиент" };
  }
  const { count, error } = await supabase
    .from("voice_recordings")
    .select("id", { count: "exact", head: true })
    .eq("training_round_id", recording.training_round_id!)
    .lte("created_at", recording.created_at);
  if (error || count == null) {
    console.error("evaluate-recording: не смог посчитать попытку", error);
    return { attempt: 1, source: `подсчёт не удался (${error?.message ?? "нет count"}) — считаем первой` };
  }
  return { attempt: count, source: "подсчёт строк (старый клиент)" };
}

/**
 * Фраза раунда на изучаемом языке — из соло-раунда или из раунда боя, смотря
 * чей это слот. Пустая строка, если фразы нет: и подсказка распознавателю, и
 * эталон судье без неё просто не передаются.
 */
async function roundPhrase(
  supabase: SupabaseClient,
  recording: VoiceRecordingRow,
): Promise<string> {
  try {
    const { table, id } = recording.training_round_id
      ? { table: "training_rounds", id: recording.training_round_id }
      : { table: "rounds", id: recording.round_id };
    if (!id) return "";

    const { data } = await supabase
      .from(table)
      .select("generated_phrase")
      .eq("id", id)
      .maybeSingle();
    return (data?.generated_phrase ?? "").trim();
  } catch (e) {
    console.error("evaluate-recording: не смог получить фразу раунда", e);
    return "";
  }
}

/**
 * Google ждёт короткие фразы-подсказки, а не абзац целиком: разбиваем по
 * предложениям — так подсказка помогает на каждом из них, а не только при
 * точном совпадении всего текста.
 */
function hintPhrases(phrase: string): string[] {
  if (phrase.length === 0) return [];
  return phrase
    .split(/(?<=[.!?])\s+/)
    .map((part: string) => part.trim())
    .filter((part: string) => part.length > 0);
}

async function saveTranscript(
  supabase: SupabaseClient,
  recordingId: string,
  transcript: string,
  words: { word: string; confidence: number }[],
  status: TranscriptStatus,
) {
  const { error } = await supabase
    .from("voice_recordings")
    .update({
      transcript,
      word_confidences: words,
      transcript_status: status,
    })
    .eq("id", recordingId);
  // Не роняем задачу из-за этого (балл всё равно будет выставлен), но и
  // молчать нельзя: если столбца transcript_status нет, значит миграция
  // 0013 не применена, и ASR будет впустую перезапускаться на каждой
  // повторной обработке записи.
  if (error) console.error("evaluate-recording: failed to save transcript", { recordingId, error });
}

async function markDone(supabase: SupabaseClient, jobId: string) {
  await supabase.from("evaluation_jobs").update({
    status: "done",
    worker_id: "evaluate-recording",
    completed_at: new Date().toISOString(),
  }).eq("id", jobId);
}
