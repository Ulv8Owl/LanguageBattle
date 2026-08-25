// Воркер очереди evaluation_jobs (раздел 9.8). Вызывается триггером на
// INSERT в evaluation_jobs (см. supabase/migrations/0004_ai_pipeline_trigger.sql).
// Клиент никогда не ждёт эту функцию синхронно — он подписан на
// round_scores/training_rounds через Realtime и узнаёт о результате, когда
// воркер его допишет.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { evaluateGrammar } from "../_shared/evaluateGrammar.ts";

const CONFIDENCE_THRESHOLD = 0.5;

interface WordConfidence {
  word: string;
  start?: number;
  end?: number;
  confidence: number;
}

function wordCharRanges(transcript: string, words: WordConfidence[]): { start: number; end: number; confidence: number }[] {
  const ranges: { start: number; end: number; confidence: number }[] = [];
  let cursor = 0;
  for (const w of words) {
    const idx = transcript.indexOf(w.word, cursor);
    if (idx === -1) continue;
    const start = idx;
    const end = idx + w.word.length;
    ranges.push({ start, end, confidence: w.confidence });
    cursor = end;
  }
  return ranges;
}

function overlaps(aStart: number, aEnd: number, bStart: number, bEnd: number): boolean {
  return aStart < bEnd && bStart < aEnd;
}

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
      await supabase.from("evaluation_jobs").update({
        status: "done",
        worker_id: "evaluate-recording",
        completed_at: new Date().toISOString(),
      }).eq("id", job_id);
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

    let confirmedErrors: { offset_start: number; length: number; message: string; replacement: string; category: string; suppressed: boolean }[] = [];
    let score: number;

    if (transcript.length === 0) {
      score = 1;
    } else {
      const { errors } = await evaluateGrammar(transcript, targetLanguage, nativeLanguage);
      const words: WordConfidence[] = Array.isArray(recording.word_confidences) ? recording.word_confidences : [];
      const wordRanges = wordCharRanges(transcript, words);

      confirmedErrors = errors.map((e) => {
        const overlappingConfidences = wordRanges
          .filter((w) => overlaps(e.offset, e.offset + e.length, w.start, w.end))
          .map((w) => w.confidence);
        const minConfidence = overlappingConfidences.length > 0 ? Math.min(...overlappingConfidences) : 1;
        const suppressed = minConfidence < CONFIDENCE_THRESHOLD;
        return {
          offset_start: e.offset,
          length: e.length,
          message: e.message,
          replacement: e.replacement,
          category: e.category,
          suppressed,
        };
      });

      const wordCount = Math.max(transcript.split(/\s+/).filter(Boolean).length, 1);
      const penalized = confirmedErrors.filter((e) => !e.suppressed && e.category !== "style").length;
      const density = penalized / wordCount;
      score = Math.min(10, Math.max(1, 10 - Math.round(density * 10)));
    }

    if (confirmedErrors.length > 0) {
      await supabase.from("grammar_errors").insert(
        confirmedErrors.map((e) => ({
          voice_recording_id: recording.id,
          offset_start: e.offset_start,
          length: e.length,
          message: e.message,
          replacement: e.replacement,
          category: e.category,
          suppressed: e.suppressed,
        })),
      );
    }

    const feedback = confirmedErrors.filter((e) => !e.suppressed).length === 0
      ? "Отлично, ошибок не найдено!"
      : confirmedErrors.filter((e) => !e.suppressed).map((e) => e.message).slice(0, 3).join(" ");

    if (recording.round_id) {
      await supabase.from("round_scores").upsert(
        { round_id: recording.round_id, user_id: recording.user_id, score, ai_feedback: feedback },
        { onConflict: "round_id,user_id" },
      );
    } else if (recording.training_round_id) {
      await supabase.from("training_rounds").update({ final_score: score }).eq("id", recording.training_round_id);
    }

    await supabase.from("evaluation_jobs").update({
      status: "done",
      worker_id: "evaluate-recording",
      completed_at: new Date().toISOString(),
    }).eq("id", job_id);

    return new Response(JSON.stringify({ ok: true, score }), { status: 200 });
  } catch (e) {
    console.error("evaluate-recording failed:", e);
    if (jobId) {
      await supabase.from("evaluation_jobs").update({ status: "failed" }).eq("id", jobId).catch(() => {});
    }
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
