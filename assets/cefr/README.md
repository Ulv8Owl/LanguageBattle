# CEFR phrase dataset (EN / RU / ES)

18 files + validator.

## Naming

- `phrases_<LEVEL>_<lang>.txt` — 10 phrases, one per line

`LEVEL` ∈ A1 A2 B1 B2 C1 C2 · `lang` ∈ en ru es

## No explanation files any more

The dataset used to ship `explanations_<LEVEL>_<lang>.txt` with a
pre-written note per element. They were removed: such a note is written
about the *native* wording («в семь», not "at seven") and knows nothing
about what the learner actually said. The per-element commentary is now
written by the language model at answer time, and only for the elements
the learner got wrong — see
`supabase/functions/_shared/explainElements.ts`.

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

Checks: 18 files present · 10 lines per phrase file · sentence count per level ·
element count per level · en/ru/es element parity per line.
