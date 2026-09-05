#!/usr/bin/env python3
"""Validation of the 18 CEFR phrase files: line counts, sentence counts,
element counts, 1:1 alignment across languages.

Explanation files are gone: the per-element commentary is now written by
the language model at answer time (see
supabase/functions/_shared/explainElements.ts), because a pre-written text
cannot know what the learner actually said."""
import os, re, sys

DIR = os.path.dirname(os.path.abspath(__file__))
LEVELS = ["A1", "A2", "B1", "B2", "C1", "C2"]
LANGS = ["en", "ru", "es"]
SENT = {"A1": 2, "A2": 3, "B1": 4, "B2": 5, "C1": 6, "C2": 7}

errors = []
report = []


def sentences(line):
    # count sentence-final punctuation outside of quotes
    return len(re.findall(r"[.!?]+(?=\s|$)", line))


for level in LEVELS:
    expected_sent = SENT[level]
    expected_elem = expected_sent * 3
    per_lang = {}
    for lang in LANGS:
        pf = os.path.join(DIR, f"phrases_{level}_{lang}.txt")
        if not os.path.exists(pf):
            errors.append(f"MISSING FILE: {os.path.basename(pf)}")
            continue

        lines = [l for l in open(pf, encoding="utf-8").read().split("\n") if l.strip()]
        if len(lines) != 10:
            errors.append(f"{os.path.basename(pf)}: {len(lines)} lines, expected 10")

        elems = []
        for i, line in enumerate(lines, 1):
            n_el = line.count("|")
            n_se = sentences(line)
            elems.append(n_el)
            if n_se != expected_sent:
                errors.append(f"{os.path.basename(pf)} line {i}: {n_se} sentences, expected {expected_sent}")
            if n_el != expected_elem:
                errors.append(f"{os.path.basename(pf)} line {i}: {n_el} elements, expected {expected_elem}")
        per_lang[lang] = elems

        report.append(f"{level} {lang}: phrases={len(lines)} elements/line={set(elems)}")

    # cross-language alignment
    if len(per_lang) == 3:
        for i in range(10):
            vals = {lang: per_lang[lang][i] for lang in LANGS}
            if len(set(vals.values())) != 1:
                errors.append(f"{level} line {i+1}: element mismatch across languages {vals}")

print("\n".join(report))
print("-" * 60)
if errors:
    print(f"{len(errors)} PROBLEM(S):")
    for e in errors:
        print("  -", e)
    sys.exit(1)
print("ALL CHECKS PASSED: 18 files, 10 phrases each, sentence/element counts correct,")
print("en/ru/es aligned 1:1.")
