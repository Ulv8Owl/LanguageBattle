#!/usr/bin/env python3
"""Собирает assets/phrases/cefr_<уровень>.json из assets/cefr/*.txt.

ИСТОЧНИК — 18 текстовых файлов в assets/cefr: по шесть уровней (A1..C2) на
каждый из трёх языков. Формат описан в assets/cefr/README.md и проверяется
assets/cefr/validate.py; здесь он только читается.

ГОТОВЫХ ПОЯСНЕНИЙ БОЛЬШЕ НЕТ. Раньше рядом лежали файлы explanations_* с
заранее написанным разбором каждого элемента, и он попадал в этот JSON.
От них отказались: пояснение писалось про РОДНУЮ формулировку («в семь», а
не «at seven») и ничего не знало о том, что игрок сказал на самом деле.
Разбор ошибок теперь пишет языковая модель по факту ответа — см.
supabase/functions/_shared/explainElements.ts.

ЧТО СОБИРАЕТСЯ. Один JSON на уровень — то, что реально нужно приложению в
раунде, без разбора текста на клиенте:

    [
      {
        "elements": {                       // по элементам, en/ru/es
          "en": [{"lead": "", "text": "I get up"},
                 {"lead": " ", "text": "at seven"}, ...],
          ...
        },
        "tail": {"en": ".", ...}            // хвост строки после последнего
                                            // элемента: точка, «!», «?»
      },
      ...
    ]

Почему элемент разложен на lead и text, а не хранится куском. Разделитель
«|» в исходнике ставится сразу после последнего слова, поэтому знак
препинания и пробел, идущие следом, попадают в НАЧАЛО следующего элемента:
«. Then I make». В игре элемент — это то, по чему игрок тыкает, чтобы
подсмотреть перевод, и переворачиваться вместе со словами не должна ни
точка предыдущего предложения, ни пробел. Разложив их один раз здесь, мы
избавляем клиент от разбора пунктуации в каждом кадре.

Запуск:
    python3 tools/build_cefr.py            # собрать
    python3 tools/build_cefr.py --check    # только сверить, не писать
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = REPO_ROOT / "assets" / "cefr"
OUT_DIR = REPO_ROOT / "assets" / "phrases"

LEVELS = ["A1", "A2", "B1", "B2", "C1", "C2"]
LANGUAGES = ["en", "ru", "es"]

# Сколько элементов во фразе каждого уровня. Не «сколько получилось», а
# требование: три элемента на предложение, предложений — по уровню
# (A1: 2 → 6, C2: 7 → 21). Расхождение означает битый исходник, и собирать
# из него банк фраз нельзя.
ELEMENTS_PER_LEVEL = {"A1": 6, "A2": 9, "B1": 12, "B2": 15, "C1": 18, "C2": 21}

PHRASES_PER_LEVEL = 10

# Начало элемента до первой «настоящей» буквы: пунктуация предыдущего
# предложения плюс пробелы. Класс \w здесь не годится — он не знает про
# апострофы в «don't» и про кириллицу в некоторых сборках Python.
LEAD_RE = re.compile(r"^[\s.,;:!?…—–-]*")


class SourceError(Exception):
    """Исходник не соответствует формату. Всегда останавливает сборку:
    молча собрать банк фраз с уехавшей нумерацией хуже, чем не собрать."""


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        raise SourceError(f"нет файла {path.relative_to(REPO_ROOT)}")
    raw = path.read_text(encoding="utf-8").split("\n")
    while raw and raw[-1] == "":
        raw.pop()
    for i, line in enumerate(raw, start=1):
        if line.strip() == "":
            raise SourceError(f"{path.relative_to(REPO_ROOT)}: пустая строка {i}")
    return raw


def split_elements(line: str, where: str) -> tuple[list[dict[str, str]], str]:
    """Строка с «|» → список элементов и хвост.

    Возвращает ([{lead, text}, ...], tail). Сложение всех lead+text и хвоста
    в исходном порядке обязано дать ровно ту же строку без «|» — это
    проверяется тут же, потому что именно эта строка потом показывается
    игроку.
    """
    if "|" not in line:
        raise SourceError(f"{where}: в строке нет ни одного разделителя «|»")
    parts = line.split("|")
    # Последний кусок — то, что идёт после последнего «|»: обычно точка.
    tail = parts[-1]
    body = parts[:-1]

    elements: list[dict[str, str]] = []
    for part in body:
        lead = LEAD_RE.match(part).group(0)
        text = part[len(lead):]
        if text.strip() == "":
            raise SourceError(f"{where}: пустой элемент — «{part}»")
        elements.append({"lead": lead, "text": text})

    rebuilt = "".join(e["lead"] + e["text"] for e in elements) + tail
    if rebuilt != line.replace("|", ""):
        raise SourceError(f"{where}: разбор не сходится с исходной строкой")
    return elements, tail


def load_phrases(level: str, lang: str) -> tuple[list[list[dict[str, str]]], list[str]]:
    path = SOURCE_DIR / "phrases" / lang.upper() / f"phrases_{level}.txt"
    lines = read_lines(path)
    if len(lines) != PHRASES_PER_LEVEL:
        raise SourceError(
            f"{path.name}: {len(lines)} фраз, а должно быть {PHRASES_PER_LEVEL}"
        )
    expected = ELEMENTS_PER_LEVEL[level]
    all_elements: list[list[dict[str, str]]] = []
    tails: list[str] = []
    for i, line in enumerate(lines, start=1):
        elements, tail = split_elements(line, f"{path.name}:{i}")
        if len(elements) != expected:
            raise SourceError(
                f"{path.name}:{i}: {len(elements)} элементов, а на {level} должно быть {expected}"
            )
        all_elements.append(elements)
        tails.append(tail)
    return all_elements, tails


def build_level(level: str) -> list[dict]:
    elements_by_lang: dict[str, list[list[dict[str, str]]]] = {}
    tails_by_lang: dict[str, list[str]] = {}

    for lang in LANGUAGES:
        elements_by_lang[lang], tails_by_lang[lang] = load_phrases(level, lang)

    # Паритет между языками: элемент N фразы M обязан существовать во всех
    # трёх языках, иначе подсказка «переверни элемент» покажет чужой кусок.
    for i in range(PHRASES_PER_LEVEL):
        counts = {lang: len(elements_by_lang[lang][i]) for lang in LANGUAGES}
        if len(set(counts.values())) != 1:
            raise SourceError(f"{level}, фраза {i + 1}: разное число элементов по языкам: {counts}")

    phrases = []
    for i in range(PHRASES_PER_LEVEL):
        phrases.append({
            "elements": {lang: elements_by_lang[lang][i] for lang in LANGUAGES},
            "tail": {lang: tails_by_lang[lang][i] for lang in LANGUAGES},
        })
    return phrases


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="не писать файлы, только сообщить, актуальны ли они")
    args = parser.parse_args()

    stale: list[str] = []
    try:
        for level in LEVELS:
            phrases = build_level(level)
            out = OUT_DIR / f"cefr_{level.lower()}.json"
            new_text = json.dumps(phrases, ensure_ascii=False) + "\n"
            old_text = out.read_text(encoding="utf-8") if out.exists() else None
            changed = old_text != new_text
            if args.check:
                if changed:
                    stale.append(str(out.relative_to(REPO_ROOT)))
                continue
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(new_text, encoding="utf-8")
            print(f"{out.relative_to(REPO_ROOT)}: {len(phrases)} фраз по "
                  f"{ELEMENTS_PER_LEVEL[level]} элементов — "
                  f"{'обновлён' if changed else 'без изменений'}")
    except SourceError as e:
        print(f"ОСТАНОВ: {e}", file=sys.stderr)
        return 1

    if args.check:
        if stale:
            print("Устарели (запусти tools/build_cefr.py и закоммить результат):")
            for path in stale:
                print(f"  {path}")
            return 1
        print("assets/phrases/cefr_*.json актуальны относительно assets/cefr/.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
