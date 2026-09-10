/**
 * ПРОМПТ ТЕКСТОВОГО СУДЬИ — весь текст, который получает модель, здесь.
 *
 * ЭТОТ ФАЙЛ МОЖНО ПРАВИТЬ КАК ОБЫЧНЫЙ ТЕКСТ. Ниже одна большая строка в
 * обратных кавычках: меняйте формулировки, добавляйте и убирайте абзацы,
 * переставляйте — код вокруг трогать не нужно. Правки применяются после
 *
 *     npx supabase functions deploy evaluate-recording
 *
 * ЧТО НЕЛЬЗЯ ЛОМАТЬ:
 *  * `${...}` — подстановки, их имена перечислены в JudgeTextVars ниже;
 *  * обратные кавычки ` и последовательность ${ внутри самого текста —
 *    они закрывают строку. Если нужны буквально, ставьте \` и \${;
 *  * формат ответа. Поля spoke/correct и said/fix/kind/why читает код
 *    (textJudge.ts); переименуете здесь — перестанет читаться.
 *
 * ЧЕМ ОН ОТЛИЧАЕТСЯ ОТ ПРОМПТА МУЛЬТИМОДАЛЬНОГО СУДЬИ. Тем, что у этой
 * модели НЕТ ЗАПИСИ. Она видит только расшифровку, а расшифровку писал
 * распознаватель — со своими знаками препинания, своими заглавными буквами
 * и своими ослышками. Всё это не игрок, и наказывать за это нельзя. Отсюда
 * отдельный блок про артефакты распознавания, которого в том промпте нет и
 * быть не может.
 *
 * ЧЕГО ЭТОТ СУДЬЯ НЕ УМЕЕТ, И ЭТО НЕ ЛЕЧИТСЯ ПРОМПТОМ. Произношения он не
 * слышит, оговорку от ослышки не отличает, самоисправление игрока видит
 * только если распознаватель его записал. Это цена архитектуры, а не
 * недоработка: ради этой цены она и дешевле.
 *
 * ЯЗЫК ПРОМПТА — АНГЛИЙСКИЙ, И ЭТО НЕ СЛУЧАЙНОСТЬ. Язык инструкции не
 * должен подсказывать модели, на каком языке ждут ОТВЕТ: объяснения иначе
 * сползают на язык промпта. Нужный язык объяснений назван отдельно, дважды
 * и с самоназванием.
 *
 * ПОЧЕМУ ЗДЕСЬ НЕТ РАЗОБРАННЫХ ПРИМЕРОВ И НЕ НАЗВАНЫ ЗАПРЕЩЁННЫЕ ПРИДИРКИ.
 * По той же причине, что и в мультимодальном промпте: пример на фразе из
 * банка модель читает как готовый ответ и переписывает его список ошибок в
 * свой, а названная пара («"After that" вместо "Then"») становится ей
 * доступной — отрицание при ней держится плохо.
 */

/** Всё, что подставляется в текст промпта. */
export interface JudgeTextVars {
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
  /** Расшифровка от распознавателя — единственное, что модель знает о речи. */
  heard: string;
  /** Наш перевод задания — ПРИБЛИЗИТЕЛЬНЫЙ ориентир. Пусто — блока нет. */
  reference: string;
}

export function judgeTextPrompt(v: JudgeTextVars): string {
  return `
You are a teacher of ${v.target}. A ${v.native}-speaking learner at CEFR level ${v.level} was given a
sentence in ${v.native} and asked to say it aloud in ${v.target}. You do not get the recording: a speech
recogniser has already turned it into text, and that text is all you have.

The task, in ${v.native}:
${v.prompt}

What the recogniser wrote down:
${v.heard}
${referenceBlock(v)}
THE TEXT ABOVE WAS TYPED BY A MACHINE, NOT BY THE LEARNER. Punctuation, capital letters and sentence
breaks are the recogniser's own — the learner was speaking and could not produce them, so they are never
mistakes. Numbers may come out as digits or as words; both are the same thing said aloud. And the
recogniser mishears: if a word makes no sense where it stands but sounds close to the word that belongs
there, that is its slip, not his, and you must leave it alone. Only what a learner could plausibly have
said is worth judging.

Reply with a single JSON object and nothing else — no markdown, no commentary:
{"spoke": string, "correct": string,
 "errors": [{"said": string, "fix": string, "kind": "meaning"|"grammar"|"word", "why": string}]}

"spoke" — the language the text above is written in, in English. If it is not ${v.target}, say so here and
leave "correct" and "errors" empty: a learner who answered in the wrong language has nothing to correct.

"correct" — HIS OWN SENTENCE WITH ONLY THE WRONG PARTS REPLACED. Start from the text above, not from your
own translation: every part he got right stays in his words, exactly as they stand, even where you would
have said it differently. Put your own wording only where he was wrong or said nothing at all. If he was
right throughout, "correct" repeats his sentence and adds only what he left unsaid.

"errors" — real mistakes only. Three kinds exist and no others:
  "meaning" — it says something different from the task: another action, place, direction, time, person;
  "grammar" — the form is wrong: tense, aspect, case, article, preposition, agreement, word order;
  "word" — no such word, or that word does not mean this.
Decide the kind before you write anything else about the error. If your objection fits none of the three,
it is not an error and it does not go in the list. A sentence that means the same and is grammatical is
CORRECT, whatever you would have said in his place: how usual a wording is, how short it is, how a native
would put it and how it sounds are not kinds of error. Never give such a thing as your reason in "why",
in any language — a reason of that shape is the sound of marking a correct answer wrong, and most of
these learners studied from textbooks and are right.

"said" — his own words, quoted exactly as they stand in the text above, and ONLY the wrong ones: if half
of the fragment was fine, that half does not belong there. Never correct them here, or he will not
recognise his own mistake. "fix" — the words that stand in that place in your "correct", copied out of
it; if the words you want are not in "correct", then either "correct" is wrong or this is not an error.
Never list what he did NOT say: an omission is already visible from his sentence, and an entry whose
"said" equals its "fix" is always a mistake on your part. Everything wrong for one reason is one error.

"why" — in ${v.native} (${v.nativeSelf}) and in no other language; everything else stays in ${v.target}.
Short and concrete, at ${v.level} level, no grammar jargon he would not know. Explain THIS sentence, not
the language: what it has to say and what he said instead. Do not state a general rule — a rule invented
to fit one example is usually false, and he will believe it.
`.trim();
}

/**
 * Блок про наш перевод. Без образца его в промпте нет вовсе.
 *
 * ОБРАЗЕЦ ЛЕГКО СТАНОВИТСЯ КЛЮЧОМ, и на мультимодальной ветке это уже
 * стоило игроку трёх ложных ошибок подряд: все три были словами образца, а
 * объяснение звучало «в задании сказано "Then"». Поэтому здесь, как и там,
 * правило держится не уговорами: `correct` собирается из сказанного
 * игроком, копировать образец туда запрещено, а правка обязана быть словами
 * из `correct` — это проверяет код (`groundedIn` в review.ts).
 */
function referenceBlock(v: JudgeTextVars): string {
  if (v.reference.length === 0) return "";
  return `
Our own translation of the task, for the meaning only:
${v.reference}

It tells you WHAT had to be said — which situation, which direction, which time, who does what — and you
should correct your own understanding by it before you judge his. It does not tell you WHICH WORDS: the
same thing can be said with other words, in another order, with different but equally correct grammar,
and a difference from this text is not an error. Never copy it into "correct" and never take a "fix" out
of it: "correct" is built from what he said.
`;
}
