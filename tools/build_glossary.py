#!/usr/bin/env python3
"""Собирает ПОСЛОВНЫЕ переводы фраз CEFR и проверяет их на месте.

ЗАЧЕМ ОТДЕЛЬНЫЙ СЛОЙ, КОГДА ЕСТЬ ЭЛЕМЕНТЫ. Элемент — это кусок смысла
(«в семь» ↔ "at seven"), и для подсказки в Одиночной Игре его достаточно.
В Тренировке игрок выбирает слова, которых НЕ ЗНАЕТ, и элементом тут не
обойтись: не знать можно «семь», зная «в». Поэтому здесь у каждого слова
свой перевод, а элемент остаётся тем, что удерживает контекст.

ИСТОЧНИК:

    assets/cefr/glossary/<РОДНОЙ>-<ЦЕЛЕВОЙ>/glossary_<LEVEL>.txt

Формат строки — тот же, что у пояснений, чтобы не заводить второй:

    <фраза>.<элемент> «<текст элемента на РОДНОМ языке>» — слово=перевод; слово=перевод

Скобки «» держат ЯКОРЬ: он сверяется с файлом фраз символ в символ, и
перевод не может молча съехать на соседний кусок. Слова слева от «=» тоже
сверяются: их последовательность обязана совпасть со словами элемента —
иначе подсветка в игре встанет не на то слово.

ЧТО СОБИРАЕТСЯ:

    assets/phrases/gloss_<уровень>_<родной>-<целевой>.json

    [                                  // 10 фраз
      [                                // элементы фразы
        [["Я", "I"], ["встаю", "get up"]],
        ...
      ],
      ...
    ]

Отдельным файлом на пару и уровень — по той же причине, что и пояснения:
игроку нужна ровно одна пара из шести.

ЧЕГО ФАЙЛА МОЖЕТ НЕ БЫТЬ. Уровень без глоссария — это не поломка: клиент
в таком случае показывает перевод ЭЛЕМЕНТА целиком (см. PhraseGlossary в
lib/data/phrase_glossary.dart). Хуже, чем пословный, но лучше, чем пусто,
и Тренировка работает на всех уровнях с первого дня.

Запуск:  python3 tools/build_glossary.py [--check]
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PHRASES = ROOT / "assets" / "cefr" / "phrases"
GLOSSARY = ROOT / "assets" / "cefr" / "glossary"
OUT = ROOT / "assets" / "phrases"

LANGS = ["EN", "RU", "ES"]
LEVELS = ["A1", "A2", "B1", "B2", "C1", "C2"]

# Слово — то же, что считает словом клиент (lib/data/phrase_glossary.dart).
# Две разные нарезки означали бы, что подсветка и перевод расходятся.
WORD_RE = re.compile(r"[^\W\d_]+(?:['’\-][^\W\d_]+)*|\d+", re.UNICODE)

LINE_RE = re.compile(r"^(\d+)\.(\d+)\s+«(.+?)»\s+—\s+(.*)$")


def words_of(text: str):
    return WORD_RE.findall(text)


def read_elements(lang: str, level: str):
    """Элементы каждой фразы уровня: [[текст, ...], ...] по 10 фразам."""
    path = PHRASES / lang / f"phrases_{level}.txt"
    phrases = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        # Хвост после последнего «|» — точка: элементом он не является.
        parts = line.split("|")
        elements = [p.strip() for p in parts[:-1]]
        # Ведущая пунктуация принадлежит предыдущему предложению, а не
        # элементу: «. Потом я делаю» — элемент это «Потом я делаю».
        elements = [re.sub(r"^[\s.,!?;:—-]+", "", e) for e in elements]
        phrases.append(elements)
    return phrases


def parse_glossary(native: str, target: str, level: str, elements):
    """Разбирает файл глоссария и сверяет его с фразами. Возвращает
    (данные, список ошибок). Отсутствие файла — не ошибка."""
    path = GLOSSARY / f"{native}-{target}" / f"glossary_{level}.txt"
    if not path.exists():
        return None, []

    errors = []
    data = [[None] * len(p) for p in elements]
    seen = set()

    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = LINE_RE.match(line)
        if not m:
            errors.append(f"{path.name}:{number}: строка не по формату")
            continue
        phrase_no, element_no, anchor, body = int(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
        if not (1 <= phrase_no <= len(elements)):
            errors.append(f"{path.name}:{number}: нет фразы {phrase_no}")
            continue
        phrase_elements = elements[phrase_no - 1]
        if not (1 <= element_no <= len(phrase_elements)):
            errors.append(f"{path.name}:{number}: во фразе {phrase_no} нет элемента {element_no}")
            continue
        key = (phrase_no, element_no)
        if key in seen:
            errors.append(f"{path.name}:{number}: элемент {phrase_no}.{element_no} описан дважды")
            continue
        seen.add(key)

        expected_anchor = phrase_elements[element_no - 1]
        if anchor != expected_anchor:
            errors.append(
                f"{path.name}:{number}: якорь «{anchor}» ≠ «{expected_anchor}»")
            continue

        pairs = []
        for chunk in body.split(";"):
            chunk = chunk.strip()
            if not chunk:
                continue
            if "=" not in chunk:
                errors.append(f"{path.name}:{number}: «{chunk}» без знака =")
                continue
            word, gloss = chunk.split("=", 1)
            pairs.append([word.strip(), gloss.strip()])

        expected_words = words_of(expected_anchor)
        got_words = [w for w, _ in pairs]
        if got_words != expected_words:
            errors.append(
                f"{path.name}:{number}: слова {got_words} ≠ слов элемента {expected_words}")
            continue
        if any(not gloss for _, gloss in pairs):
            errors.append(f"{path.name}:{number}: у какого-то слова пустой перевод")
            continue

        data[phrase_no - 1][element_no - 1] = pairs

    missing = [
        f"{path.name}: не описан элемент {i + 1}.{j + 1}"
        for i, phrase in enumerate(data)
        for j, element in enumerate(phrase)
        if element is None
    ]
    # Неполный файл собирать нельзя: дырка в середине уровня выглядела бы
    # на экране как случайно неработающее слово.
    errors.extend(missing[:10])
    if len(missing) > 10:
        errors.append(f"{path.name}: … и ещё {len(missing) - 10} элементов без перевода")

    return data, errors


def main():
    check_only = "--check" in sys.argv
    all_errors = []
    written = []
    skipped = []

    for level in LEVELS:
        elements_by_lang = {lang: read_elements(lang, level) for lang in LANGS}
        for native in LANGS:
            for target in LANGS:
                if native == target:
                    continue
                data, errors = parse_glossary(native, target, level, elements_by_lang[native])
                all_errors.extend(errors)
                name = f"gloss_{level.lower()}_{native.lower()}-{target.lower()}.json"
                if data is None or errors:
                    skipped.append(name)
                    continue
                if not check_only:
                    (OUT / name).write_text(
                        json.dumps(data, ensure_ascii=False, separators=(",", ":")),
                        encoding="utf-8",
                    )
                written.append(name)

    for error in all_errors:
        print("ОШИБКА:", error)
    print(f"собрано файлов: {len(written)}; без глоссария: {len(skipped)}")
    if skipped:
        print("  (на этих уровнях Тренировка покажет перевод элемента целиком)")
    return 1 if all_errors else 0


if __name__ == "__main__":
    sys.exit(main())
