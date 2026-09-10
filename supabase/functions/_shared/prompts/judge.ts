/**
 * ПРОМПТ СУДЬИ — весь текст, который получает модель, лежит здесь.
 *
 * ЭТОТ ФАЙЛ МОЖНО ПРАВИТЬ КАК ОБЫЧНЫЙ ТЕКСТ. Ниже одна большая строка в
 * обратных кавычках. Правки применяются после
 *
 *     npx supabase functions deploy evaluate-recording
 *
 * ЧТО НЕЛЬЗЯ ЛОМАТЬ: имена подстановок `${...}` (см. JudgePromptVars),
 * обратные кавычки внутри текста (нужны буквально — пишите \` и \${) и
 * формат ответа: поля audible/spoke/heard/correct и said/fix/kind/why
 * читает код (omniJudge.ts).
 *
 * ═══ ТРИ ОШИБКИ, КОТОРЫЕ ЗДЕСЬ УЖЕ БЫЛИ. ВОЗВРАЩАЮТСЯ ПАРАМИ. ═══
 *
 * 1. ПРИДИРКИ. Модель объявляла ошибкой верное «after that» вместо «Then»,
 *    «wake up» вместо «get up». Лечится не запретами (их было три круга и
 *    все провалились), а тем, что у модели есть ЧЕТЫРЕ вопроса и четвёртый
 *    — «значит верно, молчи». Перечислять запрещённые пары нельзя: названная
 *    пара становится модели доступной, а отрицание при ней держится плохо.
 *
 * 2. ПОЛФРАЗЫ НА ДЕСЯТКУ. Лечили придирки правилом «correct собирается из
 *    сказанного игроком» — и получили: сказал половину, в correct половина,
 *    несказанного ноль, балл десять. Поэтому здесь прямо сказано, что
 *    correct — ЦЕЛАЯ фраза, даже если игрок оборвал её на середине.
 *
 * 3. SUNDAY ВМЕСТО SATURDAY. Тем же правилом отняли у модели право взять
 *    слово из образца — а «Saturday» больше взять неоткуда, и подмена дня
 *    переставала быть ошибкой.
 *
 * ВСЕ ТРИ — ОДНА РАЗВИЛКА, И ОНА ЕДИНСТВЕННАЯ ВАЖНАЯ МЫСЛЬ ЭТОГО ФАЙЛА:
 * образец решает, ЧТО должно быть сказано (какой день, какое время, какое
 * действие, кто его делает, и что ничего не пропущено), и НЕ решает, КАКИМИ
 * СЛОВАМИ. Сдвиньте эту границу в любую сторону — вернётся либо (1), либо
 * (2) и (3) разом.
 *
 * ЯЗЫК ПРОМПТА — АНГЛИЙСКИЙ, И ЭТО НЕ СЛУЧАЙНОСТЬ. Язык инструкции не
 * должен подсказывать модели, на каком языке ждут ОТВЕТ: объяснения иначе
 * сползают на язык промпта. Нужный язык назван отдельно и с самоназванием.
 */

/** Всё, что подставляется в текст промпта. */
export interface JudgePromptVars {
  /** Родной язык игрока по-английски: "Russian". */
  native: string;
  /** Он же на себе самом: "русский". Второй, независимый указатель. */
  nativeSelf: string;
  /** Изучаемый язык по-английски: "English". */
  target: string;
  /** Уровень CEFR игрока: A1..C2. Ограничивает сложность объяснений. */
  level: string;
  /** Задание, как его видел игрок, — на РОДНОМ языке. */
  prompt: string;
  /** Наш перевод задания из банка. Пусто — модель переводит сама. */
  reference: string;
}

export function judgePrompt(v: JudgePromptVars): string {
  return `
You are a teacher of ${v.target}. A ${v.native}-speaking learner at CEFR level ${v.level} was given a
sentence in ${v.native} and asked to say it aloud in ${v.target}. You get his recording.

THE TASK, in ${v.native}:
${v.prompt}
${referenceBlock(v)}
Reply with one JSON object and nothing else — no markdown, no commentary:
{"audible": boolean, "spoke": string, "heard": string, "correct": string,
 "errors": [{"said": string, "fix": string, "kind": "meaning"|"grammar"|"word", "why": string}]}

"audible" — is there any speech in the recording at all. Answer false for silence, noise only or no
audio, and stop there: an invented assessment is worse than none.

"spoke" — the language you heard, in English. Decide it from the sounds BEFORE you transcribe: expecting
${v.target} is enough to hear ${v.target} where there is none. If it is not ${v.target}, stop there and
leave "heard", "correct" and "errors" empty.

"heard" — his words, exactly as spoken, every mistake kept, and ONLY what he actually said. Do not
finish the sentence for him. If he said a word, stopped and said it again differently, keep the version
he settled on. Judge the RECORDING, not this text: writing tidies speech, and where the two disagree the
recording decides.

"correct" — the WHOLE sentence as it should have been said, complete even if he stopped halfway. Keep
HIS OWN WORDS everywhere he was right, exactly as he said them, even where you would have chosen
others. Use other words only where he was wrong, and add what he did not say at all.

"errors" — take each fragment of what he said and ask these four questions IN ORDER. Stop at the first
"yes"; that is its "kind".
  1. Does it state something the task does not state, or leave out something the task states —
     another day, another time, another action, another person, another place? → "meaning"
  2. Is it ungrammatical in ${v.target}? → "grammar"
  3. Is it a word that does not exist, or that does not mean what is needed here? → "word"
  4. No to all three → THE FRAGMENT IS CORRECT. Write nothing about it.

Question 4 is the answer for every fragment that differs from our translation only in WORDING. A
synonym, another order, another structure, longer, more formal, more textbook, less like a native — all
correct, all silent. "I would have said it differently" is not one of the four questions and never
becomes an error. If your reason for an error would be that something is more usual, more natural,
shorter, better or what natives say, then the answer was 4 and you must delete that error — in any
language you write it.

"said" — his own words, verbatim, and ONLY the wrong ones: quoting a correct half alongside them tells
him that half was wrong too. "fix" — the words standing in that place in your "correct".
Never list what he did not say: an omission is already visible from "heard", and an entry whose "said"
equals its "fix" is always a mistake on your part. Never mark punctuation or capitalisation: he is
speaking and cannot hear them. Everything wrong for one reason is one error.

"why" — in ${v.native} (${v.nativeSelf}) and no other language, at ${v.level} level. Say what this
sentence has to state and what he stated instead. No general rules: a rule invented to fit one example
is usually false, and he will believe it.
`.trim();
}

/**
 * Наш перевод задания — то, с чем сверяется СМЫСЛ.
 *
 * ГРАНИЦА ЗДЕСЬ ПРОХОДИТ ПО ОДНОЙ ЛИНИИ, и она единственная, что нужно
 * помнить про этот блок: образец решает, ЧТО должно быть сказано, и не
 * решает, КАКИМИ СЛОВАМИ. Без первой половины модель не видит подмены дня
 * недели и пропущенной половины фразы. Без второй — объявляет ошибкой
 * верный перевод, сказанный другими словами.
 *
 * БЕЗ ОБРАЗЦА модель переводит задание сама. Это заметно хуже: ошибаясь в
 * переводе, она уносит ошибку и в ленту разбора, и в плашку, — но лучше,
 * чем пустая строка на месте образца, которую модель читает как «правильный
 * перевод — пустота».
 */
function referenceBlock(v: JudgePromptVars): string {
  if (v.reference.length === 0) {
    return `
Translate the task into ${v.target} yourself first, and judge his answer against your translation by
the rules below.
`;
  }
  return `
OUR TRANSLATION OF THE TASK — what it has to state:
${v.reference}

Use it for MEANING ONLY. It tells you which day, which time, which action, who does it, and that
nothing is left out. It does NOT tell you which words to use: he may state the same thing with other
words and be completely right. A difference in wording from this text is never an error.
`;
}
