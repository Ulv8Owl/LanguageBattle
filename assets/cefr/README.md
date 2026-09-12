# CEFR phrase dataset (EN / RU / ES)

18 phrase files + 36 explanation files + validator.

## Layout

```
phrases/<LANG>/phrases_<LEVEL>.txt                        18 files
explanations/<NATIVE>-<TARGET>/explanations_<LEVEL>.txt   36 files
```

`LEVEL` ∈ A1 A2 B1 B2 C1 C2 · `LANG` ∈ EN RU ES ·
pair directories: EN-RU EN-ES RU-EN RU-ES ES-EN ES-RU

## Why explanations are per pair, not per language

An explanation has to know two things at once: which language to be
written in (the learner's own) and which language it is about (the one
being learned). A per-language layout gives only the second half — and
that is exactly how the previous version broke: a learner on the ru→en
pair was shown a note about the *Russian* wording («в семь») instead of
the English one ("at seven").

The directory is named NATIVE-TARGET, in the same order as the learner's
own pair: `RU-EN` is Russian text about English.

## Explanation line format

```
<phrase>.<element> «<element text in the TARGET language>» — <explanation>
```

The guillemets hold an *anchor*: `validate.py` checks it against the
phrase file character by character, so an explanation can never silently
drift onto the neighbouring chunk. Only the part after ` — ` reaches the
learner; the element text itself is already the heading of the panel.

Inside the explanation, words of the target language are quoted with
double quotes (`"at seven"`), and the validator requires at least one such
quote per line.

`tools/cefr_explanations.py` fills the anchors in from the phrase files —
typing 4860 of them by hand would guarantee typos:

```
python3 tools/cefr_explanations.py skeleton A1 en          # blank template
python3 tools/cefr_explanations.py fill A1 ru en < bodies  # "1.1 <text>" lines
```

## Word-level glossary (Тренировка)

```
glossary/<NATIVE>-<TARGET>/glossary_<LEVEL>.txt
```

Same line shape as the explanations, so there is only one format to learn:

```
<phrase>.<element> «<element text in the NATIVE language>» — слово=перевод; слово=перевод
```

The guillemets hold the same kind of anchor, checked character by
character; the words left of `=` are checked too — their sequence has to
match the element's words exactly, or a translation would silently land on
the neighbouring word. Build and check with:

```
python3 tools/build_glossary.py --check
python3 tools/build_glossary.py
```

**Why a word needs its own translation when elements already align.** An
element is a piece of meaning; in Тренировка the learner marks the words he
does NOT know, and «семь» can be unknown while «в» is not.

**Words that have no separate counterpart** (articles, a preposition the
other language does not use, a copula) still get a translation: the
smallest phrase that carries them, or a short note in the target language
(`the=нет артикля`, `las=no article`). A word whose card is empty is worse
than a word whose card explains why it is empty.

**A missing level is not a bug.** Without a glossary file each word of an
element gets the translation of the WHOLE element — coarser, but Тренировка
works on all six levels from day one (see `PhraseGlossary` in
lib/data/phrase_glossary.dart).

## Structure

| Level | Sentences per phrase | Elements per phrase |
|---|---|---|
| A1 | 2 | 6 |
| A2 | 3 | 9 |
| B1 | 4 | 12 |
| B2 | 5 | 15 |
| C1 | 6 | 18 |
| C2 | 7 | 21 |

Rule: exactly 3 elements per sentence at every level.

## Element delimiter

`|` is placed immediately after the last word of an element; punctuation that follows
belongs to the next element (or trails the line), exactly as in the spec example:

```
I usually| walk to work|, but today| I am taking the bus|. The weather| is really bad|.
```

Element numbering is `<line>.<element>`, both 1-based. Element `(2,4)` = 4th element of line 2.

## Cross-language alignment

Element counts are identical across `en` / `ru` / `es` for every line, and element *N*
of line *M* covers the same semantic chunk in all three languages. Element boundaries are
placed at clause level so the alignment survives the differences in word order.

## Validation

```
python3 validate.py
```

Checks: all 54 files present · 10 lines per phrase file · sentence count per
level · element count per level · en/ru/es element parity per line ·
explanation numbering complete and unique · anchors matching the target-language
elements · a target-language quote in every explanation · the explanation
language matching its pair directory.
