# CEFR phrase dataset (EN / RU / ES)

36 files + validator.

## Naming

- `phrases_<LEVEL>_<lang>.txt` — 10 phrases, one per line
- `explanations_<LEVEL>_<lang>.txt` — one explanation per line, prefixed `line.element`

`LEVEL` ∈ A1 A2 B1 B2 C1 C2 · `lang` ∈ en ru es

## Structure

| Level | Sentences per phrase | Elements per phrase | Explanation lines per file |
|---|---|---|---|
| A1 | 2 | 6 | 60 |
| A2 | 3 | 9 | 90 |
| B1 | 4 | 12 | 120 |
| B2 | 5 | 15 | 150 |
| C1 | 6 | 18 | 180 |
| C2 | 7 | 21 | 210 |

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

## Explanations

Written in the language of the phrases they annotate, and calibrated to the level:

- **A1–A2** — basic forms: articles, cases, prepositions of time and place, verb endings
- **B1** — aspect/perfect tenses, phrasal verbs, conditionals, relative clauses, collocations
- **B2** — register, hedging, passive/impersonal constructions, understatement
- **C1** — irony, scare quotes, corporate euphemism, cleft and fronting, connotation
- **C2** — discourse structure, why a specific punctuation mark or word order carries the joke,
  litotes, ellipsis, register shifts

## Validation

```
python3 validate.py
```

Checks: 36 files present · 10 lines per phrase file · sentence count per level ·
element count per level · en/ru/es element parity per line ·
every element has exactly one explanation, numbered in order, no gaps or duplicates.
