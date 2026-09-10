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
// ОДИН ШАГ. Мультимодальная модель слушает запись, сама переводит задание
// и сравнивает услышанное со своим переводом (_shared/textJudge.ts).
// Раньше шагов было два: распознавание превращало речь в текст, а
// текстовый судья сравнивал текст с эталоном. Оба удалены. Распознавание
// теряло всё, что слышно только в звуке; судья наказывал за правильный
// перевод, сказанный иначе, чем в эталоне.
//
// БАЛЛ СЧИТАЕТ ВОРКЕР, а не модель: доля несказанного плюс по баллу за
// ошибку (scoreFor). Числовая оценка от модели гуляла на два-три балла на
// одной и той же записи и не объяснялась игроку.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { type CefrLevel, NEUTRAL_SCORE, SILENT_SCORE } from "../_shared/cefr.ts";
import { correctText, type JudgeResult, scoreFor } from "../_shared/review.ts";
import { textJudge } from "../_shared/textJudge.ts";

/**
 * Лига говорящего приравнена к уровню CEFR (см. supabase/migrations/0023 —
 * те же границы, что и league_index_for_rating/cefr_level_for_elo там,
 * продублировано здесь, потому что Edge Function не может импортировать
 * SQL). Если меняете пороги — меняйте в обоих местах.
 *
 * На вход идёт league_rating — целочисленный рейтинг Эло, то самое
 * число, которое показано игроку как его рейтинг и по которому ему
 * выдаются фразы. На Glicko-2 это была отдельная консервативная оценка
 * (rating - 2*RD), и путать её с сырым рейтингом было легко.
 */
function cefrLevelForRating(leagueRating: number): CefrLevel {
  if (leagueRating < 1200) return "A1";
  if (leagueRating < 1500) return "A2";
  if (leagueRating < 1800) return "B1";
  if (leagueRating < 2100) return "B2";
  if (leagueRating < 2400) return "C1";
  return "C2";
}

/** Статусы работы судьи — CHECK у voice_recordings (миграции 0014, 0024). */
/// Значения voice_recordings.judge_status (миграции 0014, 0024).
///
/// 'wrong_language' вернулся в дело: он был заведён под проверку языка в
/// распознавании, та проверка ушла вместе с распознавателем, а теперь на
/// тот же вопрос отвечает сама модель.
type JudgeStatus = "pending" | "ok" | "degraded" | "skipped" | "wrong_language";

/** Балл за ответ не на том языке: задание не выполнено. */

/**
 * Определения языка в пайплайне НЕТ, и это осознанное решение.
 *
 * Здесь стояла проверка «ответил не на том языке»: распознавателю давали
 * родной язык игрока вторым кандидатом, и если он объявлял, что услышал
 * именно родной, задание считалось невыполненным. На практике это ловило
 * не тех: распознаватель, которому дали выбор языка, слышит речь
 * неносителя хуже и принимает сильный акцент за другой язык. Правильный
 * английский ответ возвращался как «Minita a New Phone My Old Bad Work» с
 * вердиктом «услышан русский» — то есть игрок получал 1 балл за верный
 * ответ на верном языке.
 *
 * Теперь распознаватель слушает РОВНО тот язык, на который игрок
 * переводит (см. _shared/asr/*.ts), и вопрос «а на том ли языке он
 * говорил» пайплайну не задаётся вовсе. Защита от чтения задания вслух
 * вместо перевода будет сделана отдельно и другим способом.
 */

/** Поля voice_recordings, которыми пользуется воркер. */
/**
 * Сколько всего отпущено фоновой задаче.
 *
 * Воркер Edge Function живёт ограниченное время, и это ограничение внешнее:
 * когда оно наступает, процесс убивают, минуя любые наши catch и finally.
 * Раньше суммарный бюджет пайплайна (60 с распознавание + 180 с судья) был
 * заведомо больше — то есть в затяжном случае результат не записывался
 * НИКОГДА, задача навсегда оставалась в 'processing', а игрок смотрел на
 * спиннер до собственного таймаута клиента.
 *
 * Поэтому бюджет теперь наш, он меньше платформенного, и до его конца мы
 * обязаны успеть записать хоть какой-то результат.
 */
const JOB_BUDGET_MS = Number(Deno.env.get("JOB_BUDGET_MS") ?? 125_000);

/** Запас на запись результатов в базу — тратить его на модель нельзя. */
const WRITE_RESERVE_MS = 15_000;

/**
 * Цена платных вызовов в энергии (миграция 0032).
 *
 * Энергия платит не за вход в режим, а за то, что стоит денег: одно
 * распознавание речи и один ответ модели. Разница в цене отражает разницу
 * в стоимости: ответ модели дороже и дольше.
 */

/**
 * Сколько стоит один вызов мультимодальной модели.
 *
 * Три — ровно столько же, сколько стоила прежняя связка: 1 за
 * распознавание и 2 за разбор. Один вызов делает работу обоих, и брать за
 * него меньше значило бы менять экономику игры заодно с пайплайном, а это
 * отдельное решение, которое никто не принимал.
 */
// Два вызова вместо одного, но списание по-прежнему одно: игрок платит
// за разбор, а не за наше устройство пайплайна.
const ENERGY_COST_JUDGE = Number(
  Deno.env.get("ENERGY_COST_JUDGE") ?? Deno.env.get("ENERGY_COST_OMNI") ?? 3,
);

/**
 * Счётчик энергии одной задачи.
 *
 * ЧЕГО ОН НЕ ДЕЛАЕТ: не решает, звать ли провайдера. Списание идёт ПОСЛЕ
 * ответа, потому что «есть ответ» — единственный момент, когда точно
 * известно, что деньги потрачены. Игрок с пустым запасом может успеть
 * получить ещё один ответ, и это осознанный размен: не пустить его в
 * следующую сессию — задача start_training_session, а обрывать уже
 * оплаченный вызов на полпути было бы хуже для всех.
 *
 * ЧТО БЕСПЛАТНО: Дуэль и Спарринг (энергия — механика Одиночной Игры) и
 * проверка уровня при регистрации. Признак проверки лежит в
 * training_sessions.is_placement и читается ЛЕНИВО, на первом списании:
 * у большинства задач списаний нет вовсе, и лишний запрос к базе им ни к
 * чему.
 *
 * НИКОГДА НЕ БРОСАЕТ. Балл к этому моменту посчитан, ответ провайдера
 * получен, и уронить запись результата из-за бухгалтерии значило бы
 * наказать игрока за нашу же ошибку.
 */
function createEnergyMeter(supabase: SupabaseClient, recording: VoiceRecordingRow) {
  const spent: { reason: string; amount: number }[] = [];
  let skipReason: string | null = recording.training_round_id
    ? null
    : "энергию тратит только Одиночная Игра";
  let placementChecked = false;

  async function isFree(): Promise<string | null> {
    if (skipReason) return skipReason;
    if (placementChecked) return null;
    placementChecked = true;
    const { data, error } = await supabase
      .from("training_rounds")
      .select("training_sessions(is_placement)")
      .eq("id", recording.training_round_id!)
      .maybeSingle();
    if (error) {
      // Не знаем, проверка это или нет. Списываем: не взять с игры хуже,
      // чем взять с проверки, — второе он заметит и скажет, первое не
      // заметит никто.
      console.error("energy: не удалось прочитать is_placement", error);
      return null;
    }
    const session = (data as { training_sessions?: { is_placement?: boolean } } | null)
      ?.training_sessions;
    if (session?.is_placement === true) {
      skipReason = "проверка уровня бесплатна";
      return skipReason;
    }
    return null;
  }

  return {
    async charge(amount: number, reason: string): Promise<void> {
      if (!(amount > 0)) return;
      const free = await isFree();
      if (free) {
        spent.push({ reason: `${reason}: не списано (${free})`, amount: 0 });
        return;
      }
      // Клиент Supabase не бросает на ошибке RPC, а возвращает её полем —
      // без этой проверки неудачное списание записалось бы в отладку как
      // удачное, и «энергия не уходит» пришлось бы ловить вручную.
      const { error } = await supabase.rpc("spend_energy", {
        p_user_id: recording.user_id,
        p_amount: amount,
        p_reason: reason,
      });
      if (error) {
        console.error("energy: списание не прошло", { reason, amount, error });
        spent.push({ reason: `${reason}: списать не удалось (${error.message})`, amount: 0 });
        return;
      }
      spent.push({ reason, amount });
    },
    debug(): Record<string, unknown> {
      return {
        total: spent.reduce((sum, s) => sum + s.amount, 0),
        items: spent,
      };
    },
  };
}

interface VoiceRecordingRow {
  id: string;
  user_id: string;
  round_id: string | null;
  training_round_id: string | null;
  recording_slot: string;
  language_code: string | null;
  audio_storage_path: string;
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
  // Отсчёт бюджета — от самого начала фоновой работы, а не от вызова
  // модели: скачивание аудио и чтения из базы тратят то же самое время.
  const jobStartedAt = Date.now();
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
    const budgetLeft = () => JOB_BUDGET_MS - (Date.now() - jobStartedAt) - WRITE_RESERVE_MS;

    // Родной язык игрока нужен ДО распознавания, а не только судье: он
    // уходит в ASR альтернативой, чтобы распознаватель мог сказать «это
    // вообще-то русский», а не подбирать целевые слова под родную речь.
    //
    // Берём его с КОНКРЕТНОЙ пары (user_languages.native_for, миграция
    // 0025), а не общий users.native_language: у полиглота с несколькими
    // родными разные пары могут быть anchored на разные из них
    // («английский от русского», «японский от китайского»), и подставлять
    // сюда всегда один и тот же язык значило бы объяснять ошибки на
    // языке, которым игрок в этой паре не пользуется. native_for бывает
    // null у пар, которых backfill миграции не затронул, — тогда честно
    // откатываемся на общий родной.
    //
    // ПОЧЕМУ ЗДЕСЬ order, А НЕ maybeSingle. После миграции 0034 у игрока
    // может быть ДВЕ пары с одним изучаемым языком (ru-en и es-en).
    // maybeSingle на двух строках возвращает ошибку и пустые данные — то
    // есть родной язык молча откатывался на общий users.native_language.
    // Игрок с русским в этой паре получал разбор на испанском: язык
    // объяснений брался не от той пары. Активная пара — та, которой сейчас
    // играют, и именно её родной здесь нужен.
    const { data: pairs } = await supabase
      .from("user_languages")
      .select("native_for, is_active")
      .eq("user_id", recording.user_id)
      .eq("role", "learning")
      .eq("language_code", targetLanguage)
      .order("is_active", { ascending: false })
      .order("native_for")
      .limit(1);
    let nativeLanguage = pairs?.[0]?.native_for ?? null;
    if (!nativeLanguage) {
      const { data: speaker } = await supabase
        .from("users")
        .select("native_language")
        .eq("id", recording.user_id)
        .single();
      nativeLanguage = speaker?.native_language ?? "en";
    }

    // Кто платит за платные вызовы этой задачи. Заводится до первого из
    // них, но в базу не ходит, пока списывать нечего.
    const energy = createEnergyMeter(supabase, recording);

    // Два шага пайплайна: распознавание превращает речь в текст, текстовая
    // модель этот текст судит (_shared/textJudge.ts).
    //
    // ЭТО АРХИТЕКТУРА ДО OMNI, ВОССТАНОВЛЕННАЯ РАДИ СРАВНЕНИЯ ЦЕНЫ. За
    // аудио платит только первый шаг — модель заточенная ровно под одно
    // дело и заметно дешевле мультимодальной; судье достаётся текст.
    // Платим за это тем, что судья не слышит записи: произношение,
    // ударение, проглоченное окончание до него не доезжают, а распознаватель
    // вдобавок приглаживает речь.
    // Задание на РОДНОМ языке — единственное, что модель получает кроме
    // звука. Эталон ей не показывают намеренно: увидев его, она начнёт
    // сверять с одним вариантом вместо того, чтобы оценивать перевод
    // (см. textJudge.ts).
    const prompt = await roundPrompt(supabase, recording, nativeLanguage);
    // Наш перевод задания — ПРИБЛИЗИТЕЛЬНЫЙ ориентир для модели.
    //
    // Раньше его не передавали вовсе: с эталоном модель требовала
    // совпадения слово в слово и наказывала за верный перевод, сказанный
    // иначе. Но без него ошибалась она сама — «мы гуляем в парке»
    // превращалось в «we go to the park», и неверное направление уходило и
    // в ленту разбора, и в плашку ошибки. Сверять было не с чем.
    //
    // Промпт трижды говорит, что это один из верных вариантов, а не
    // единственный: он решает, ЧТО должно быть сказано, и не решает,
    // КАКИМИ словами (см. prompts/judge.ts).
    const reference = await roundReference(supabase, recording);
    const level = cefrLevelForRating(
      (await speakerLeagueRating(supabase, recording.user_id, targetLanguage)) ?? 1000,
    );

    // Какими моделями разбирать — выбор игрока из настроек, читается на
    // КАЖДОЙ записи: ветка существует ради сравнения, и переключаться нужно
    // уметь между двумя ответами подряд.
    const models = await speakerJudgeModels(supabase, recording.user_id);

    const verdict = await runJudge(
      supabase,
      recording,
      targetLanguage,
      nativeLanguage,
      prompt,
      reference,
      level,
      budgetLeft(),
      models,
    );
    // Один вызов — одно списание, и только когда модель ответила. Отказ
    // провайдера бесплатен: энергия платит за ответ, а не за попытку.
    if (!verdict.degraded) {
      await energy.charge(ENERGY_COST_JUDGE, "распознавание и разбор");
    }

    // Диагностика пайплайна для отладочной панели в игре (миграция 0016).
    const pipelineDebug: Record<string, unknown> = { judge: verdict.debug };

    // Номер попытки — только для отладочной панели: попытка в раунде одна,
    // и решений по этому числу больше не принимается.
    const attempt = recording.training_round_id
      ? await trainingAttemptNumber(supabase, recording)
      : { attempt: 1, source: "PvP" };
    const attemptNumber = attempt.attempt;

    // Шаг 2 — что записать. Исходов три: модель разобрала ответ, модель не
    // ответила (наш сбой), модель ответила «речи не слышу».
    let score: number;
    let errors: {
      offset: number;
      length: number;
      message: string;
      replacement: string;
      category: string;
      /**
       * Фрагмент того, что игрок СКАЗАЛ. Есть только у ошибок от
       * мультимодальной модели: она проводит границы по смыслу, и
       * указать в эталон, как это делают поэлементные ошибки, ей нечем.
       */
      spanText?: string;
    }[] = [];
    let feedback: string;

    let judgeStatus: JudgeStatus;
    // Что мы услышали в записи. 'ok' — речь разобрана; 'empty' — модель
    // послушала и речи не нашла; 'pending' — до разбора дело не дошло.
    let transcriptStatus: "pending" | "ok" | "empty" = "ok";
    let correctedText = "";
    let cleanedText = "";
    // Лента разбора: по ней клиент красит и зачёркивает. null — разбора
    // нет (модель не ответила), и клиент честно показывает пустоту.
    let reviewSpans: { k: string; t: string }[] | null = null;

    if (verdict.wrongLanguage) {
      // Игрок говорил не на том языке. Разбирать нечего: всё, что «совпало»
      // с изучаемым языком, — плод ожидания модели, а не его слова.
      // В соло балла нет и раунд отвечается заново; в бою раунд обязан
      // сдвинуться, и там это ноль — сказанное не на том языке переводом
      // не является.
      score = SILENT_SCORE;
      feedback = `Ответ прозвучал не на том языке (${verdict.spokenLanguage ?? "?"}).`;
      judgeStatus = "wrong_language";
      pipelineDebug.judge = {
        status: "wrong_language",
        heard_language: verdict.spokenLanguage,
      };
    } else if (verdict.silent) {
      // Модель послушала запись и речи не разобрала. Это НЕ наш сбой:
      // аудио до неё доехало, мы сами его отправили и знаем его размер.
      //
      // В СОЛО БАЛЛА ЗА ТАКУЮ ЗАПИСЬ НЕТ — как и за неответ модели. Ноль
      // закрывал бы раунд оценкой за то, чего мы не слышали: игрок просто
      // говорил неразборчиво, и правильный ответ ему — сказать ещё раз, а
      // не итог с нулём. Балл ниже ставится только для боя, где раунд не
      // сдвинется без оценки обоих.
      score = SILENT_SCORE;
      transcriptStatus = "empty";
      feedback = "В записи не разобрать речи — балл минимальный.";
      // Судью не звали по существу: разбирать было нечего.
      judgeStatus = "skipped";
      pipelineDebug.judge = { status: "silent", reason: "речи в записи не разобрать" };
    } else if (verdict.degraded) {
      // Модель не ответила. Балла за такую запись НЕТ ВОВСЕ — ни плохого,
      // ни нейтрального: мы не знаем, как игрок ответил, и любое число
      // здесь будет выдумкой, которую он примет за оценку. В соло раунд
      // остаётся неоценённым, и игрок отвечает заново.
      //
      // В бою так нельзя: там раунд не сдвинется, пока у обоих нет балла,
      // и соперник будет ждать нашего сбоя. Поэтому в PvP по-прежнему
      // ставится нейтральный — см. запись балла ниже.
      score = NEUTRAL_SCORE;
      transcriptStatus = "pending";
      feedback = "Не удалось разобрать ответ — балл выставлен нейтральным.";
      judgeStatus = "degraded";
      pipelineDebug.judge = {
        status: "degraded",
        reason: verdict.failureReason ?? "модель не ответила",
      };
      console.error("evaluate-recording: модель деградировала", {
        recordingId: recording.id,
        reason: verdict.failureReason,
      });
    } else {
      pipelineDebug.round = {
        attempt: attemptNumber,
        attempt_source: attempt.source,
        budget_left_ms: budgetLeft(),
      };
      {
        const judged = verdict;
        // БАЛЛ СЧИТАЕМ МЫ, а не модель. Числовая оценка от неё была самой
        // шаткой частью ответа — на одной записи гуляла на два-три балла и
        // объяснить её игроку было нечем. Здесь арифметика: доля
        // несказанного плюс по баллу за ошибку, и это проговаривается
        // одной фразой.
        score = scoreFor(judged.review, judged.errors.length);

        // «Разбор:» — перевод, сделанный САМОЙ моделью. Не эталон из
        // датасета: его она не видела. Склеивается из той же ленты, что
        // рисует подсветку, поэтому разойтись они не могут.
        correctedText = correctText(judged.review);

        // Ошибка привязана к ФРАГМЕНТУ сказанного, а не к элементу
        // эталона: границы модель провела по смыслу, и указывать ими в
        // эталон нечем. Смещения поэтому нулевые — клиент ищет плашку по
        // тексту.
        errors = judged.errors.map((e) => ({
          offset: 0,
          length: 0,
          message: e.message,
          replacement: e.correction,
          // «omni» здесь остаётся, хотя мультимодальной модели на этой ветке
          // нет: это значение ограничено CHECK-ом в grammar_errors, а
          // CHECK в Postgres умеет только расти. Заводить ради переименования
          // новую категорию и мигрировать живые строки — цена выше пользы;
          // чем разобрана запись, видно из pipeline_debug.judge.
          category: "omni",
          spanText: e.text,
        }));

        // `m` — перевод несказанного куска. Едет ВМЕСТЕ с куском, а не
        // отдельным списком: список пришлось бы сводить с лентой по тексту
        // уже на клиенте, и на первой же неточности плашка потерялась бы.
        reviewSpans = judged.review.map((s) => ({
          k: s.kind,
          t: s.text,
          ...(s.means && s.means.length > 0 ? { m: s.means } : {}),
        }));
        judgeStatus = "ok";
        const missed = judged.review.filter((s) => s.kind === "miss").length;
        feedback = judged.errors.length === 0 && missed === 0
          ? "Отлично, ошибок не найдено!"
          : `Ошибок: ${judged.errors.length}, пропущено кусков: ${missed}.`;
        pipelineDebug.judge = {
          mode: "мультимодальная модель: переводит сама, сравнивает с услышанным",
          scoring: "программа: доля несказанного + по баллу за ошибку",
          score,
          ...judged.debug,
        };
      }
    }

    // Списания — в ту же отладочную панель, что и остальной пайплайн:
    // «сколько ушло и за что» должно быть видно там же, где видно, что
    // именно сработало. Ставится последней строкой перед записью, чтобы
    // попали все списания задачи.
    pipelineDebug.energy = energy.debug();

    await supabase
      .from("voice_recordings")
      .update({
        judge_status: judgeStatus,
        transcript_status: transcriptStatus,
        pipeline_debug: pipelineDebug,
        corrected_text: correctedText,
        cleaned_text: cleanedText,
        review_spans: reviewSpans,
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
          span_text: e.spanText ?? null,
        })),
      );
    }

    if (recording.round_id) {
      // PvP: балл за раунд.
      await supabase.from("round_scores").upsert(
        { round_id: recording.round_id, user_id: recording.user_id, score, ai_feedback: feedback },
        { onConflict: "round_id,user_id" },
      );
    } else if (
      recording.training_round_id && !verdict.degraded && !verdict.silent && !verdict.wrongLanguage
    ) {
      // Одиночная Игра: в раунде одна запись, и балл за неё окончательный.
      // Раньше попыток было две, и балл ставился по второй — по той, где
      // игрок повторял фразу, только что показанную ему в разборе. Это
      // проверяло память на один ответ, а не язык.
      //
      // Когда разобрать было нечего — модель не ответила или речи в
      // записи не нашла, — БАЛЛ НЕ СТАВИТСЯ. Раньше это были нейтральные
      // семь и ноль соответственно, и оба числа закрывали раунд оценкой
      // за то, чего никто не слышал. Пустой final_score клиент читает как
      // «оцени заново» и возвращает микрофон.
      await supabase
        .from("training_rounds")
        .update({ final_score: score })
        .eq("id", recording.training_round_id);
    }

    await markDone(supabase, job_id);
    console.log("evaluate-recording: готово", { job_id, score, judge_status: judgeStatus });
  } catch (e) {
    // Задача ОБЯЗАНА получить конечный статус в любом случае: клиент ждёт
    // 'done'/'failed' через Realtime, и оставленный 'processing' — это
    // бесконечный спиннер у игрока.
    console.error("evaluate-recording failed:", e);
    await supabase.from("evaluation_jobs").update({ status: "failed" }).eq("id", job_id);
  }
}

/** Лига говорящего на этом языке — из неё выводится уровень CEFR. */
async function speakerLeagueRating(
  supabase: SupabaseClient,
  userId: string,
  targetLanguage: string,
): Promise<number | null> {
  const { data } = await supabase
    .from("user_languages")
    .select("league_rating")
    .eq("user_id", userId)
    .eq("language_code", targetLanguage)
    .eq("role", "learning")
    .maybeSingle();
  return (data?.league_rating as number | null) ?? null;
}

/**
 * Задание раунда на РОДНОМ языке игрока — то, что он видел на экране.
 *
 * Сервер не может вывести его сам: банк фраз лежит в приложении, а не в
 * базе. Поэтому клиент присылает ровно ту строку, которую показал, а мы её
 * читаем (миграция 0037).
 *
 * Пустая строка — не катастрофа: модель тогда оценивает запись без
 * задания, то есть просто слышит речь на изучаемом языке. Балл в таком
 * случае честнее нейтрального, но и врать про «не тот перевод» она не
 * станет — сравнивать ей будет не с чем.
 */
/**
 * Наш перевод задания на изучаемый язык — из датасета фраз.
 *
 * Лежит в generated_phrase: клиент пишет его при создании раунда и в соло,
 * и в бою. Ошибку чтения глушим — без образца модель работает как прежде,
 * а ронять из-за него задачу нечем.
 */
async function roundReference(
  supabase: SupabaseClient,
  recording: VoiceRecordingRow,
): Promise<string> {
  try {
    const table = recording.training_round_id ? "training_rounds" : "rounds";
    const id = recording.training_round_id ?? recording.round_id;
    if (!id) return "";
    const { data } = await supabase
      .from(table)
      .select("generated_phrase")
      .eq("id", id)
      .maybeSingle();
    return ((data?.generated_phrase as string | null) ?? "").trim();
  } catch (e) {
    console.error("evaluate-recording: не удалось прочитать образец раунда", e);
    return "";
  }
}

async function roundPrompt(
  supabase: SupabaseClient,
  recording: VoiceRecordingRow,
  nativeLanguage: string,
): Promise<string> {
  try {
    if (recording.training_round_id) {
      const { data } = await supabase
        .from("training_rounds")
        .select("prompt_text")
        .eq("id", recording.training_round_id)
        .maybeSingle();
      return (data?.prompt_text ?? "").trim();
    }
    if (!recording.round_id) return "";
    // В Дуэли соперники видят фразу каждый на своём родном языке, и модели
    // нужно то задание, которое видел ИМЕННО оцениваемый игрок.
    const { data } = await supabase
      .from("rounds")
      .select("prompt_by_language")
      .eq("id", recording.round_id)
      .maybeSingle();
    const map = data?.prompt_by_language as Record<string, unknown> | null;
    const value = map?.[nativeLanguage];
    return typeof value === "string" ? value.trim() : "";
  } catch (e) {
    console.error("evaluate-recording: не удалось прочитать задание раунда", e);
    return "";
  }
}

/**
 * Единственный вызов пайплайна: звук на вход, разбор на выход.
 *
 * Никогда не бросает — сбой провайдера приходит как degraded, и балл тогда
 * нейтральный. Иначе задача осталась бы висеть в 'processing', а игрок
 * ждал бы результат, которого не будет.
 *
 * КЭША ЗДЕСЬ НЕТ, и это осознанно. Раньше повторный прогон задачи брал
 * сохранённый транскрипт и не ходил к провайдеру. Транскрипта больше нет —
 * хранить нечего, — а повтор случается только когда первая попытка не
 * дошла до записи результата, то есть звать модель заново там и надо.
 */
/** Скачивает запись из хранилища. null — не скачалась. */
async function loadAudio(
  supabase: SupabaseClient,
  recording: VoiceRecordingRow,
): Promise<Uint8Array | null> {
  const { data: file, error: downloadErr } = await supabase.storage
    .from("voice-recordings")
    .download(recording.audio_storage_path);
  if (downloadErr || !file) {
    console.error("evaluate-recording: audio download failed", {
      path: recording.audio_storage_path,
      downloadErr,
    });
    return null;
  }
  return new Uint8Array(await file.arrayBuffer());
}

/**
 * Подписанная ссылка на запись — то, чем аудио уходит распознаванию.
 *
 * ЗАЧЕМ ССЫЛКА, КОГДА ФАЙЛ УЖЕ СКАЧАН. Модели распознавания у провайдера
 * ждут в `input_audio.data` ССЫЛКУ и формат определяют сами. Файл, вложенный
 * в запрос как data-URL, они разобрать не могут и отвечают HTTP 400
 * «format is empty» — при том, что формат мы передаём и он непустой.
 *
 * Бакет закрытый, поэтому ссылка подписанная и живёт пятнадцать минут:
 * дольше, чем любой разбор, и заметно меньше, чем срок жизни самой записи.
 * Не получилось подписать — не беда: распознавание умеет и вложением, это
 * просто дороже и работает не со всеми моделями.
 */
async function audioLink(
  supabase: SupabaseClient,
  recording: VoiceRecordingRow,
): Promise<string | null> {
  try {
    const { data, error } = await supabase.storage
      .from("voice-recordings")
      .createSignedUrl(recording.audio_storage_path, 900);
    if (error || !data?.signedUrl) {
      console.error("evaluate-recording: не подписалась ссылка на запись", error);
      return null;
    }
    return data.signedUrl;
  } catch (e) {
    console.error("evaluate-recording: не подписалась ссылка на запись", e);
    return null;
  }
}

async function runJudge(
  supabase: SupabaseClient,
  recording: VoiceRecordingRow,
  targetLanguage: string,
  nativeLanguage: string,
  prompt: string,
  reference: string,
  level: CefrLevel,
  budgetMs: number,
  models: JudgeModels,
): Promise<JudgeResult> {
  const audio = await loadAudio(supabase, recording);
  if (audio === null) {
    return {
      review: [],
      errors: [],
      audible: false,
      degraded: true,
      failureReason: "не удалось скачать аудио",
      debug: { provider: "asr+llm", status: "failed", error: "аудио не скачалось" },
    };
  }

  return await textJudge({
    audioUrl: await audioLink(supabase, recording),
    audio,
    audioFormat: audioFormatOf(recording.audio_storage_path),
    nativeLanguage,
    targetLanguage,
    prompt,
    reference,
    level,
    budgetMs,
    asrModelChoice: models.asr,
    llmModelChoice: models.llm,
  });
}

/** Какими моделями разбирать эту запись — выбор игрока из настроек. */
interface JudgeModels {
  asr: string | null;
  llm: string | null;
}

/**
 * Модели, выбранные игроком в настройках (миграция 0048).
 *
 * Ошибку чтения глотаем: выбор модели — это удобство сравнения, а не
 * условие работы. Остаться без разбора из-за того, что не прочиталась одна
 * колонка профиля, было бы обменом не в ту сторону.
 */
async function speakerJudgeModels(
  supabase: SupabaseClient,
  userId: string,
): Promise<JudgeModels> {
  try {
    const { data } = await supabase
      .from("users")
      .select("asr_model, llm_model")
      .eq("id", userId)
      .maybeSingle();
    return {
      asr: (data?.asr_model as string | null) ?? null,
      llm: (data?.llm_model as string | null) ?? null,
    };
  } catch (e) {
    console.error("evaluate-recording: не удалось прочитать выбор моделей", e);
    return { asr: null, llm: null };
  }
}

/**
 * Формат контейнера по имени файла в хранилище.
 *
 * Провайдер требует назвать формат явно, а угадывать его по содержимому
 * дороже, чем прочитать расширение, которое клиент и так проставляет по
 * тому, чем писал. Неизвестное расширение считаем wav: это то, что
 * приложение пишет по умолчанию, и ошибиться тут безопаснее в сторону
 * самого частого случая.
 */
function audioFormatOf(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return ["wav", "mp3", "m4a", "aac", "ogg", "flac", "webm"].includes(ext) ? ext : "wav";
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

async function markDone(supabase: SupabaseClient, jobId: string) {
  await supabase.from("evaluation_jobs").update({
    status: "done",
    worker_id: "evaluate-recording",
    completed_at: new Date().toISOString(),
  }).eq("id", jobId);
}
