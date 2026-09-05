#!/usr/bin/env python3
"""Проверка датасета: фразы по языкам и пояснения по языковым ПАРАМ.

Раскладка (её же требует tools/build_cefr.py):

    assets/cefr/phrases/<LANG>/phrases_<LEVEL>.txt          18 файлов
    assets/cefr/explanations/<NATIVE>-<TARGET>/explanations_<LEVEL>.txt   36

ПОЧЕМУ ПОЯСНЕНИЯ РАЗЛОЖЕНЫ ПО ПАРАМ, А НЕ ПО ЯЗЫКАМ. Пояснение обязано
знать сразу две вещи: на каком языке его читать (родной язык игрока) и про
какой язык оно вообще (тот, который игрок учит). Раскладка по одному языку
даёт только вторую половину — и именно на этом прошлая версия датасета
сломалась: игроку с парой ru→en показывали разбор русской формулировки
«в семь» вместо английской "at seven".

Каталог называется РОДНОЙ-ЦЕЛЕВОЙ: RU-EN — текст по-русски про английский.
EN-RU — наоборот, по-английски про русский. Порядок тот же, что в паре
языков у игрока.

ФОРМАТ СТРОКИ ПОЯСНЕНИЯ:

    <фраза>.<элемент> «<текст элемента на ЦЕЛЕВОМ языке>» — <разбор>

Кавычки-ёлочки здесь служебные: это якорь, по которому эта проверка
сверяет пояснение с элементом фразы. Он обязан совпасть с элементом
посимвольно — иначе разбор уехал бы на соседний кусок, а заметить это на
экране почти невозможно. До игрока доезжает только часть после « — ».

Запуск: python3 assets/cefr/validate.py
"""
import os
import re
import sys

DIR = os.path.dirname(os.path.abspath(__file__))
LEVELS = ["A1", "A2", "B1", "B2", "C1", "C2"]
LANGS = ["en", "ru", "es"]
# Пары «родной-целевой». Все шесть сочетаний трёх языков: пояснение для
# ru→en и для es→en рассказывает про одну и ту же английскую форму, но
# сравнивать её приходится с разными родными языками, поэтому это два
# разных текста, а не один переведённый.
PAIRS = [(n, t) for n in LANGS for t in LANGS if n != t]
SENT = {"A1": 2, "A2": 3, "B1": 4, "B2": 5, "C1": 6, "C2": 7}
PHRASES = 10

LINE_RE = re.compile(r"^(\d+)\.(\d+) «(.+?)» — (.+)$")
CYRILLIC_RE = re.compile(r"[А-Яа-яЁё]")
# Начало элемента до первой «настоящей» буквы: знак препинания предыдущего
# предложения плюс пробелы. Ровно тем же выражением режет tools/build_cefr.py —
# и якорь пояснения сверяется именно с результатом этой резки, потому что
# игрок в заголовке разбора видит текст БЕЗ ведущей точки и пробела.
LEAD_RE = re.compile(r"^[\s.,;:!?…—–-]*")

errors = []
report = []


def phrases_path(level, lang):
    return os.path.join(DIR, "phrases", lang.upper(), f"phrases_{level}.txt")


def explanations_path(level, native, target):
    return os.path.join(
        DIR, "explanations", f"{native.upper()}-{target.upper()}", f"explanations_{level}.txt"
    )


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return [l for l in f.read().split("\n") if l.strip()]


def sentences(line):
    return len(re.findall(r"[.!?]+(?=\s|$)", line))


def check_phrases(level, lang):
    """Строки фраз -> список элементов каждой фразы. None, если файла нет."""
    path = phrases_path(level, lang)
    name = os.path.relpath(path, DIR)
    if not os.path.exists(path):
        errors.append(f"НЕТ ФАЙЛА: {name}")
        return None

    lines = read_lines(path)
    if len(lines) != PHRASES:
        errors.append(f"{name}: {len(lines)} строк, ожидалось {PHRASES}")

    expected_sent = SENT[level]
    expected_elem = expected_sent * 3
    per_phrase = []
    for i, line in enumerate(lines, 1):
        # Элементы — то, что стоит ПЕРЕД каждым «|»; хвост после
        # последнего «|» элементом не является.
        elements = [LEAD_RE.sub("", p) for p in line.split("|")[:-1]]
        per_phrase.append(elements)
        n_se = sentences(line)
        if n_se != expected_sent:
            errors.append(f"{name}:{i}: предложений {n_se}, ожидалось {expected_sent}")
        if len(elements) != expected_elem:
            errors.append(f"{name}:{i}: элементов {len(elements)}, ожидалось {expected_elem}")
        for j, el in enumerate(elements, 1):
            if not el:
                errors.append(f"{name}:{i}: элемент {j} пустой")

    report.append(f"{level} {lang}: фраз={len(lines)} элементов/строку={sorted({len(e) for e in per_phrase})}")
    return per_phrase


def check_explanations(level, native, target, target_elements):
    path = explanations_path(level, native, target)
    name = os.path.relpath(path, DIR)
    if not os.path.exists(path):
        errors.append(f"НЕТ ФАЙЛА: {name}")
        return

    lines = read_lines(path)
    expected = SENT[level] * 3
    seen = {}
    for i, line in enumerate(lines, 1):
        m = LINE_RE.match(line)
        if not m:
            errors.append(f"{name}:{i}: строка не по формату «N.M «элемент» — разбор»")
            continue
        phrase_no, element_no = int(m.group(1)), int(m.group(2))
        anchor, body = m.group(3), m.group(4).strip()

        if not (1 <= phrase_no <= PHRASES):
            errors.append(f"{name}:{i}: номер фразы {phrase_no} вне 1..{PHRASES}")
            continue
        if not (1 <= element_no <= expected):
            errors.append(f"{name}:{i}: номер элемента {element_no} вне 1..{expected}")
            continue
        key = (phrase_no, element_no)
        if key in seen:
            errors.append(f"{name}:{i}: пояснение {phrase_no}.{element_no} уже было в строке {seen[key]}")
            continue
        seen[key] = i

        # Якорь обязан совпасть с элементом ЦЕЛЕВОГО языка посимвольно.
        if target_elements is not None:
            actual = target_elements[phrase_no - 1][element_no - 1]
            if anchor != actual:
                errors.append(
                    f"{name}:{i}: якорь «{anchor}» не совпадает с элементом "
                    f"{phrase_no}.{element_no} языка {target}: «{actual}»"
                )

        if not body:
            errors.append(f"{name}:{i}: пустой разбор")
        if "|" in line:
            errors.append(f"{name}:{i}: служебный «|» не должен попадать в пояснение")
        # Требование к содержанию: слова целевого языка цитируются двойными
        # кавычками. Без цитаты игрок не понимает, о какой именно форме
        # речь, — особенно когда разбор захватывает соседний элемент.
        if body.count('"') < 2:
            errors.append(f"{name}:{i}: в разборе нет ни одной цитаты в двойных кавычках")
        # Дешёвая проверка на перепутанный язык текста: русский разбор без
        # кириллицы (или нерусский с ней) означает, что файл лёг не в тот
        # каталог пары.
        has_cyrillic = bool(CYRILLIC_RE.search(body))
        if native == "ru" and not has_cyrillic:
            errors.append(f"{name}:{i}: разбор должен быть на русском")
        if native != "ru" and target != "ru" and has_cyrillic:
            errors.append(f"{name}:{i}: в разборе кириллица, хотя ни один язык пары не русский")

    missing = [
        f"{p}.{e}"
        for p in range(1, PHRASES + 1)
        for e in range(1, expected + 1)
        if (p, e) not in seen
    ]
    if missing:
        errors.append(f"{name}: нет пояснений {', '.join(missing[:8])}"
                      + (f" и ещё {len(missing) - 8}" if len(missing) > 8 else ""))
    else:
        report.append(f"{level} {native}->{target}: пояснений {len(seen)}")


for level in LEVELS:
    by_lang = {lang: check_phrases(level, lang) for lang in LANGS}

    # Паритет между языками: элемент N фразы M обязан существовать во всех
    # трёх языках. На этом стоит механика подсказок.
    if all(v is not None for v in by_lang.values()):
        for i in range(min(PHRASES, min(len(v) for v in by_lang.values()))):
            counts = {lang: len(by_lang[lang][i]) for lang in LANGS}
            if len(set(counts.values())) != 1:
                errors.append(f"{level} строка {i + 1}: разное число элементов по языкам {counts}")

    for native, target in PAIRS:
        check_explanations(level, native, target, by_lang[target])

print("\n".join(report))
print("-" * 60)
if errors:
    print(f"ПРОБЛЕМ: {len(errors)}")
    for e in errors:
        print("  -", e)
    sys.exit(1)
print("ВСЁ СОШЛОСЬ: 18 файлов фраз и 36 файлов пояснений, нумерация сплошная,")
print("якоря совпадают с элементами целевого языка, en/ru/es выровнены 1:1.")
