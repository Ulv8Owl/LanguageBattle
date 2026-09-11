/**
 * ПРОМПТ ТЕКСТОВОГО СУДЬИ — весь текст, который получает модель, здесь.
 *
 * ЭТОТ ФАЙЛ МОЖНО ПРАВИТЬ КАК ОБЫЧНЫЙ ТЕКСТ. Правки применяются после
 *
 *     npx supabase functions deploy evaluate-recording
 *
 * ЧТО НЕЛЬЗЯ ЛОМАТЬ: имена подстановок `${...}` (см. JudgeTextVars),
 * обратные кавычки внутри текста (буквально — \` и \${) и формат ответа:
 * поля spoke/correct и said/fix/kind/why читает код (textJudge.ts).
 *
 * ЧТО МОДЕЛЬ ОТДАЁТ НА ЭТОЙ ВЕТКЕ: правильную фразу и ПЕРЕВОД тех её
 * кусков, которых игрок не сказал. Отдельного списка ошибок с объяснениями
 * здесь нет — красный текст в ленте разбора и есть плашка, а нажатие на
 * него показывает перевод.
 *
 * ОБЪЯСНЕНИЕ ИДЁТ ТУДА ЖЕ, НО ТОЛЬКО ЗА ГРАММАТИКУ. Что значат слова —
 * игрок не знает, и это перевод. Почему его «many sleep» стало «sleeps a
 * lot» — он тоже не знает, и одной фразы про правило тут мало не бывает.
 * А вот на «сказал другими словами» объяснять нечего: правки там нет.
 * Отсюда и развилка в последнем правиле промпта — перевод всегда,
 * объяснение только к грамматической правке.
 *
 * ГРАНИЦЫ КУСКОВ ПРОВОДИМ МЫ, а не модель (дифф в textJudge.ts). У модели
 * просим те же куски только затем, чтобы было к чему привязать перевод;
 * сопоставляются они по словам, и не совпавшее просто остаётся без
 * перевода — красным, но без нажатия.
 *
 * ═══ ТРИ ОШИБКИ, КОТОРЫЕ ЗДЕСЬ УЖЕ БЫЛИ. ВОЗВРАЩАЮТСЯ ПАРАМИ. ═══
 *
 1. ПРИДИРКИ. Модель переписывала верное «after that» в «Then», и игрок
 *    видел своё правильное слово зачёркнутым. Списка ошибок здесь больше
 *    нет, поэтому и придраться ей негде, кроме `correct`, — правило про
 *    него единственное, что от этого защищает. Перечислять запрещённые
 *    пары нельзя: названная пара становится модели доступной, а отрицание
 *    при ней держится плохо.
 *
 * 2. ПОЛФРАЗЫ НА ДЕСЯТКУ. Судья проверял только сказанное, и несказанного
 *    в его «правильном переводе» не оказывалось вовсе — доля пропущенного
 *    выходила нулевой. Поэтому здесь прямо сказано: correct — ЦЕЛАЯ фраза.
 *
 * 3. SUNDAY ВМЕСТО SATURDAY. Судья сверял ответ сам с собой, а не с
 *    заданием, и подмена дня недели ошибкой не считалась.
 *
 * ВСЕ ТРИ — ОДНА РАЗВИЛКА, И ОНА ЕДИНСТВЕННАЯ ВАЖНАЯ МЫСЛЬ ЭТОГО ФАЙЛА:
 * образец решает, ЧТО должно быть сказано (какой день, какое время, какое
 * действие, кто его делает, и что ничего не пропущено), и НЕ решает, КАКИМИ
 * СЛОВАМИ. Сдвиньте границу в любую сторону — вернётся либо (1), либо (2) и
 * (3) разом.
 *
 * ЧЕМ ОН ОТЛИЧАЕТСЯ ОТ ПРОМПТА МУЛЬТИМОДАЛЬНОГО СУДЬИ. У этой модели НЕТ
 * ЗАПИСИ. Она видит расшифровку, а её писал распознаватель — со своими
 * знаками препинания, заглавными буквами и ослышками. Отсюда отдельный
 * абзац про артефакты машины, которого в том промпте нет и быть не может.
 *
 * ЯЗЫК ПРОМПТА — АНГЛИЙСКИЙ, И ЭТО НЕ СЛУЧАЙНОСТЬ. Язык инструкции не
 * должен подсказывать модели, на каком языке ждут ОТВЕТ.
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
  /** Наш перевод задания из банка. Пусто — модель переводит сама. */
  reference: string;
}

export function judgeTextPrompt(v: JudgeTextVars): string {
  return `
You are a teacher of ${v.target}. A ${v.native}-speaking learner at CEFR level ${v.level} was given a
sentence in ${v.native} and asked to say it aloud in ${v.target}. You do not get the recording: a speech
recogniser has already turned it into text.

THE TASK, in ${v.native}:
${v.prompt}
${referenceBlock(v)}
WHAT HE SAID, as the recogniser wrote it down:
${v.heard}

THAT LINE WAS TYPED BY A MACHINE, NOT BY HIM. Punctuation, capital letters and sentence breaks are the
recogniser's own — he was speaking and could not produce them, so they are never mistakes. Digits and
number words are the same thing said aloud. If a word makes no sense where it stands but sounds close
to the word that belongs there, that is the recogniser mishearing him: leave it alone.

Reply with one JSON object and nothing else — no markdown, no commentary:
{"spoke": string, "correct": string, "missing": [{"text": string, "means": string}]}

"spoke" — the language that line is written in, in English. If it is not ${v.target}, stop there and
leave "correct" empty and "missing" empty.

"correct" — the WHOLE sentence as it should have been said, complete even if he stopped halfway. Keep
HIS OWN WORDS everywhere he was right, exactly as they stand, even where you would have chosen others:
a synonym, another order, another structure, longer, more formal, more textbook — all correct, and you
must leave every one of them untouched. Put other words ONLY where what he said states something the
task does not state, or is ungrammatical, or is not a real word. Add what he did not say at all.

"missing" — one entry for every stretch of "correct" that is NOT in what he said, and nothing else.
  "text" — that stretch, copied from "correct" letter for letter.
  "means" — in ${v.native} (${v.nativeSelf}) and no other language. What goes in it: the last rule below.
Split the stretches exactly where his own words come between them, and nowhere else: a run of words he
did not say is ONE entry, however long. If he said nothing at all of the sentence, that is one entry
holding the whole of "correct".

"means" — THIS IS A TRANSLATION with a brief explanation for the specific case.
If a grammatical error was made and corrected, then an explanation is required: name in one short
clause what the grammar demands here — the tense, the number, the article, the preposition, the order
of the words. If it is simply text that was not said, or an error that does not carry a visible
grammatical violation (just the wrong word in terms of meaning), then in that case "means" should
contain ONLY the translation.
The translation comes first, the explanation after it, separated by " — ", never the other way round.
Wording you would have preferred is NOT a grammatical error and gets no explanation. Keep it as short
as the sense allows, at ${v.level} level.
`.trim();
}

/**
 * Наш перевод задания — то, с чем сверяется СМЫСЛ.
 *
 * ГРАНИЦА ЗДЕСЬ ПРОХОДИТ ПО ОДНОЙ ЛИНИИ: образец решает, ЧТО должно быть
 * сказано, и не решает, КАКИМИ СЛОВАМИ. Без первой половины судья не видит
 * ни подмены дня недели, ни пропущенной половины фразы — он сверяет ответ
 * сам с собой. Без второй — объявляет ошибкой верный перевод, сказанный
 * другими словами.
 */
function referenceBlock(v: JudgeTextVars): string {
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
