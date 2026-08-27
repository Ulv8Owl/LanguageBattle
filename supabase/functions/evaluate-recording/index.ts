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
// Балл берётся НАПРЯМУЮ из ответа LLM (раздел 9.4, MVP-версия): без
// нормирующей формулы, без фильтра по категории ошибок и без сопоставления
// с confidence ASR. Все три пункта осознанно отложены — см.
// deferred_suggestions.md, не добавлять их сюда без отдельного запроса.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { type CefrLevel, evaluateGrammar } from "../_shared/evaluateGrammar.ts";

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

/** Балл за пустой транскрипт: ASR ничего не разобрал — говорить не о чем. */
const EMPTY_TRANSCRIPT_SCORE = 1;

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  let jobId: string | undefined;

  try {
    const { job_id } = await req.json();
    jobId = job_id;
    if (!job_id) {
      return new Response(JSON.stringify({ error: "job_id is required" }), { status: 400 });
    }

    const { data: job, error: jobErr } = await supabase
      .from("evaluation_jobs")
      .select("*")
      .eq("id", job_id)
      .single();
    if (jobErr || !job) {
      return new Response(JSON.stringify({ error: "job not found" }), { status: 404 });
    }
    if (job.status !== "pending") {
      // Уже обрабатывается/обработана — не задваиваем работу.
      return new Response(JSON.stringify({ skipped: true }), { status: 200 });
    }

    await supabase.from("evaluation_jobs").update({ status: "processing" }).eq("id", job_id);

    const { data: recording, error: recErr } = await supabase
      .from("voice_recordings")
      .select("*")
      .eq("id", job.voice_recording_id)
      .single();
    if (recErr || !recording) {
      await supabase.from("evaluation_jobs").update({ status: "failed" }).eq("id", job_id);
      return new Response(JSON.stringify({ error: "recording not found" }), { status: 404 });
    }

    // Голосовое на родном языке в Дуэли — только для прослушки соперником,
    // не оценивается (см. раздел 2.4).
    if (recording.recording_slot === "native") {
      await markDone(supabase, job_id);
      return new Response(JSON.stringify({ skipped: "native slot not graded" }), { status: 200 });
    }

    const { data: speaker } = await supabase
      .from("users")
      .select("native_language")
      .eq("id", recording.user_id)
      .single();

    const transcript = (recording.transcript ?? "").trim();
    const targetLanguage = recording.language_code ?? "en";
    const nativeLanguage = speaker?.native_language ?? "en";

    // Лига говорящего на этом языке -> уровень CEFR (скрытая механика,
    // раздел 9.2 чата про приравнивание лиг к A1-C2) — ограничивает только
    // сложность текста объяснений LLM, не саму оценку. Нет строки/ELO —
    // считаем новичком (1000 ELO по умолчанию, как и везде в проекте).
    const { data: speakerLanguage } = await supabase
      .from("user_languages")
      .select("elo")
      .eq("user_id", recording.user_id)
      .eq("language_code", targetLanguage)
      .eq("role", "learning")
      .maybeSingle();
    const level = cefrLevelForElo(speakerLanguage?.elo ?? 1000);

    let score = EMPTY_TRANSCRIPT_SCORE;
    let errors: { offset: number; length: number; message: string; replacement: string; category: string }[] = [];
    let degraded = false;

    if (transcript.length > 0) {
      // Одиночная Игра просит подробный разбор ошибки (раздел 2.2: игрок
      // должен понять, что исправить перед второй попыткой) — PvP получает
      // короткую пометку прямо в ленте боя. Балл считается одинаково.
      const detailed = recording.training_round_id != null;
      const result = await evaluateGrammar(transcript, targetLanguage, nativeLanguage, detailed, level);
      score = result.score;
      errors = result.errors;
      degraded = result.degraded;
    }

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

    const feedback = transcript.length === 0
      ? "Не удалось разобрать речь — попробуй сказать чётче."
      : degraded
      ? "Не удалось получить разбор от ИИ — балл выставлен нейтральным."
      : errors.length === 0
      ? "Отлично, ошибок не найдено!"
      : errors.map((e) => e.message).slice(0, 3).join(" ");

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
      const { count } = await supabase
        .from("voice_recordings")
        .select("id", { count: "exact", head: true })
        .eq("training_round_id", recording.training_round_id)
        .lte("created_at", recording.created_at);
      const attemptNumber = count ?? 1;
      if (attemptNumber >= 2) {
        await supabase
          .from("training_rounds")
          .update({ final_score: score })
          .eq("id", recording.training_round_id);
      }
    }

    await markDone(supabase, job_id);
    return new Response(JSON.stringify({ ok: true, score }), { status: 200 });
  } catch (e) {
    console.error("evaluate-recording failed:", e);
    if (jobId) {
      await supabase.from("evaluation_jobs").update({ status: "failed" }).eq("id", jobId);
    }
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});

// deno-lint-ignore no-explicit-any
async function markDone(supabase: any, jobId: string) {
  await supabase.from("evaluation_jobs").update({
    status: "done",
    worker_id: "evaluate-recording",
    completed_at: new Date().toISOString(),
  }).eq("id", jobId);
}
