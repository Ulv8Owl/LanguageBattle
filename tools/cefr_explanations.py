#!/usr/bin/env python3
"""Помощник для файлов пояснений: скелет и сборка из голых разборов.

ЗАЧЕМ ОН НУЖЕН. В строке пояснения есть якорь — текст элемента целевого
языка в «ёлочках». Он обязан совпасть с элементом фразы посимвольно
(assets/cefr/validate.py это проверяет), а элементов в датасете 4860 на все
шесть пар. Переписывать якоря руками — гарантированные опечатки; здесь они
подставляются из самих файлов фраз.

Режимы:

    python3 tools/cefr_explanations.py skeleton A1 en
        Печатает заготовку файла для целевого языка en: «1.1 «I get up» — ».
        Разбор дописывается после « — ».

    python3 tools/cefr_explanations.py fill A1 ru en < bodies.txt
        Читает строки вида «1.1<пробел>разбор», подставляет якоря и пишет
        assets/cefr/explanations/RU-EN/explanations_A1.txt. Порядок строк на
        входе не важен, но комплект обязан быть полным: недостающий или
        лишний номер — остановка, потому что съехавшая нумерация в этом
        датасете не видна ни на экране, ни в отзыве игрока.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = REPO_ROOT / "assets" / "cefr"

ELEMENTS_PER_LEVEL = {"A1": 6, "A2": 9, "B1": 12, "B2": 15, "C1": 18, "C2": 21}
PHRASES_PER_LEVEL = 10

LEAD_RE = re.compile(r"^[\s.,;:!?…—–-]*")
BODY_RE = re.compile(r"^(\d+)\.(\d+)\s+(.*)$")


def elements(level: str, lang: str) -> list[list[str]]:
    path = SOURCE_DIR / "phrases" / lang.upper() / f"phrases_{level}.txt"
    lines = [l for l in path.read_text(encoding="utf-8").split("\n") if l.strip()]
    return [[LEAD_RE.sub("", p) for p in line.split("|")[:-1]] for line in lines]


def skeleton(level: str, target: str) -> int:
    for p, row in enumerate(elements(level, target), start=1):
        for e, text in enumerate(row, start=1):
            print(f"{p}.{e} «{text}» — ")
    return 0


def fill(level: str, native: str, target: str) -> int:
    rows = elements(level, target)
    expected = ELEMENTS_PER_LEVEL[level]

    bodies: dict[tuple[int, int], str] = {}
    for i, line in enumerate(sys.stdin.read().split("\n"), start=1):
        if not line.strip():
            continue
        m = BODY_RE.match(line)
        if not m:
            print(f"ОСТАНОВ: строка {i} не начинается с «номер.номер »: {line[:60]}", file=sys.stderr)
            return 1
        key = (int(m.group(1)), int(m.group(2)))
        body = m.group(3).strip()
        if not body:
            print(f"ОСТАНОВ: строка {i}: пустой разбор {key[0]}.{key[1]}", file=sys.stderr)
            return 1
        if key in bodies:
            print(f"ОСТАНОВ: разбор {key[0]}.{key[1]} встретился дважды", file=sys.stderr)
            return 1
        bodies[key] = body

    out: list[str] = []
    for p in range(1, PHRASES_PER_LEVEL + 1):
        for e in range(1, expected + 1):
            body = bodies.pop((p, e), None)
            if body is None:
                print(f"ОСТАНОВ: нет разбора {p}.{e}", file=sys.stderr)
                return 1
            out.append(f"{p}.{e} «{rows[p - 1][e - 1]}» — {body}")
    if bodies:
        extra = ", ".join(f"{p}.{e}" for p, e in sorted(bodies))
        print(f"ОСТАНОВ: лишние номера: {extra}", file=sys.stderr)
        return 1

    path = SOURCE_DIR / "explanations" / f"{native.upper()}-{target.upper()}" / f"explanations_{level}.txt"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"{path.relative_to(REPO_ROOT)}: {len(out)} пояснений")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[0] == "skeleton":
        return skeleton(argv[1].upper(), argv[2].lower())
    if len(argv) >= 4 and argv[0] == "fill":
        return fill(argv[1].upper(), argv[2].lower(), argv[3].lower())
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
