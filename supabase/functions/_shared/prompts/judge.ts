/**
 * ПРОМПТ СУДЬИ — весь текст, который получает модель, лежит здесь.
 *
 * ЭТОТ ФАЙЛ МОЖНО ПРАВИТЬ КАК ОБЫЧНЫЙ ТЕКСТ. Ниже одна большая строка в
 * обратных кавычках: меняйте формулировки, добавляйте и убирайте абзацы,
 * переставляйте — код вокруг трогать не нужно. Правки применяются после
 *
 *     npx supabase functions deploy evaluate-recording
 *
 * ЧТО НЕЛЬЗЯ ЛОМАТЬ:
 *  * `${...}` — подстановки. Их имена перечислены в JudgePromptVars ниже;
 *    писать можно только те, что там есть.
 *  * Обратные кавычки ` и последовательность ${ внутри самого текста —
 *    они закрывают строку. Если нужны буквально, ставьте \` и \${.
 *  * Формат ответа. Поля said/fix/kind/why и audible/spoke/heard/correct
 *    читает код (omniJudge.ts); переименуете здесь — перестанет читаться.
 *
 * ПОЧЕМУ ЗДЕСЬ НЕТ РАЗОБРАННЫХ ПРИМЕРОВ. Были — на фразе «Я встаю в семь.
 * Потом я варю кофе и читаю новости», и это первая же фраза банка A1,
 * которую игроки читают чаще любой другой. Пример шёл со списком ошибок
 * («stand up → get up», «in seven → at seven»), и модель этот список
 * воспроизводила на записи, где таких ошибок не было: игрок сказал верное
 * "wake up" и получил за него «надо get up». Пример на задании, которое
 * сейчас проверяют, — это не образец рассуждения, а готовый ответ, и
 * модель берёт ответ. Иллюстрации ниже поэтому без единой настоящей фразы.
 *
 * ПОЧЕМУ ЗДЕСЬ НЕ НАЗВАНЫ ЗАПРЕЩЁННЫЕ ПРИДИРКИ. Раньше стояло списком:
 * «"After that" вместо "Then", "seven o'clock" вместо "seven" — это не
 * ошибки». Обе пары пришли к игроку ошибками. Названная пара становится
 * доступной модели, а отрицание при ней держится плохо, — поэтому правило
 * теперь сформулировано общим признаком и ничего не перечисляет.
 *
 * ПОЧЕМУ КОРОТКО. Длина не бесплатна: десять кричащих правил соперничают
 * между собой, и выигрывает не то, которое важнее, а то, которое ближе к
 * ответу. Здесь оставлено только то, что читает код, и по одному правилу
 * на каждую ошибку, которая реально приходила от модели.
 *
 * ЯЗЫК ПРОМПТА — АНГЛИЙСКИЙ, И ЭТО НЕ СЛУЧАЙНОСТЬ. Язык инструкции не
 * должен подсказывать модели, на каком языке ждут ОТВЕТ: объяснения иначе
 * сползают на язык промпта. Нужный язык объяснений назван отдельно, дважды
 * и с самоназванием.
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
  /**
   * Наш перевод задания на изучаемый язык — ПРИБЛИЗИТЕЛЬНЫЙ ориентир.
   *
   * Пусто, если для раунда его нет. Тогда блок с ним в текст не попадает
   * вовсе: пустая строка на месте образца читалась бы как «правильный
   * перевод — пустота».
   */
  reference: string;
}

export function judgePrompt(v: JudgePromptVars): string {
  return `
You are a teacher of ${v.target}. A ${v.native}-speaking learner at CEFR level ${v.level} was given a sentence
in ${v.native} and asked to say it aloud in ${v.target}. You get that sentence and his recording.
${referenceBlock(v)}
Reply with a single JSON object and nothing else — no markdown, no commentary:
{"audible": boolean, "spoke": string, "heard": string, "correct": string,
 "errors": [{"said": string, "fix": string, "kind": "meaning"|"grammar"|"word", "why": string}]}

"audible" — is there any speech in the recording at all. Answer false for silence, noise only, or no audio
at all, and stop there. Never guess in that case: an invented assessment is worse than none.

"spoke" — the language you actually heard, in English. Decide it from the sounds BEFORE you transcribe.
You are expecting ${v.target}, and expecting a language is enough to hear it: in a recording of another
language you will catch what sounds like ${v.target} words and write them down as if he had said them. If
it is not ${v.target}, say so here and leave "heard", "correct" and "errors" empty.

"heard" — what he said, word for word, in ${v.target}, with every mistake left in, and only the part he
actually said. Do not finish the sentence for him, do not repeat the task back, do not write your own
translation here. If he said half the sentence and stopped, "heard" is that half and nothing more. If he
said a word, stopped and said it again differently, keep the version he settled on and drop the abandoned
one — correcting himself is the skill working, not failing. Everything else is decided from this field.

"correct" — HIS OWN SENTENCE WITH ONLY THE WRONG PARTS REPLACED. Start from "heard", not from your own
translation: every part he got right stays in his words, exactly as he said them, even where you would
have said it differently. Put your own wording only where he was wrong or said nothing at all. If he was
right throughout, "correct" repeats "heard" and adds only what he left unsaid.

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

"said" — his own words, quoted exactly as he said them, and ONLY the wrong ones: if half of the fragment
was fine, that half does not belong there. Never correct them here, or he will not recognise his own
mistake. "fix" — the words that stand in that place in your "correct", copied out of it; if the words you
want are not in "correct", then either "correct" is wrong or this is not an error.
Never list what he did NOT say: an omission is already visible from "heard", and an entry whose "said"
equals its "fix" is always a mistake on your part. Never mark punctuation, capitalisation or sentence
boundaries: he is speaking and cannot hear them. Everything wrong for one reason is one error.

"why" — in ${v.native} (${v.nativeSelf}) and in no other language; everything else stays in ${v.target}.
Short and concrete, at ${v.level} level, no grammar jargon he would not know. Explain THIS sentence, not
the language: what it has to say and what he said instead. Do not state a general rule — a rule invented
to fit one example is usually false, and he will believe it.
`.trim();
}

/**
 * Блок про наш перевод. Без образца его в промпте нет вовсе.
 *
 * ЗАЧЕМ ОБРАЗЕЦ НУЖЕН. Модель переводит задание сама, и когда ошибается
 * она — ошибается всё: «вечером мы гуляем в парке» превращалось в «we go
 * to the park», и это неверное направление шло и в ленту разбора, и в
 * плашку ошибки. Сверять было не с чем.
 *
 * ЧЕМ ОН ОКАЗАЛСЯ НА САМОМ ДЕЛЕ. Ответом. Игрок сказал верное "I wake up
 * … After that I make coffee", а образец говорит "I get up … Then I make
 * coffee" — и модель выдала три ошибки подряд, все три словами образца, с
 * объяснением «в задании сказано Then». Три оговорки, что образец
 * приблизительный, против текста, который лежит рядом и выглядит как ключ,
 * не весят ничего.
 *
 * ПОЧЕМУ ТЕПЕРЬ ДОЛЖНО ДЕРЖАТЬСЯ. Правило перенесено с уговоров на
 * механику: "correct" собирается из СКАЗАННОГО ИГРОКОМ, а не из перевода,
 * и образец прямо запрещено туда копировать. Правка обязана быть словами
 * из "correct" — это проверяет код (groundedIn в omniJudge.ts), — так что
 * придирка словами образца отсеивается сама собой: в "correct" их нет.
 * Образцу остаётся то, ради чего он появился, — смысл.
 */
function referenceBlock(v: JudgePromptVars): string {
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
