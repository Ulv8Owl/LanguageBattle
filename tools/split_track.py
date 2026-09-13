#!/usr/bin/env python3
"""Разметка трека для «Аудирования»: текст со временем строк -> слова со
временем каждого.

ЗАЧЕМ. Руками расставлять время каждому слову — работа на часы и заведомо
впустую: внутри строки слова идут подряд, и их границы считаются, а не
угадываются. Человеку остаётся то, чего машина не знает: сам текст, время
СТРОК (его видно в любом плеере) и перевод.

КАК СЧИТАЕТСЯ ВРЕМЯ СЛОВА. Строка делится между словами пропорционально их
длине в буквах. Это приближение, и оно честно названо приближением: в живой
речи одно слово тянут, другое проглатывают. Для «Аудирования» этого хватает
— подсветка идёт в темпе строки; там, где нужна точность до доли, правьте
числа в готовом JSON, формат для того и простой.

ВХОДНОЙ ФАЙЛ (обычный текст):

    # id: my_track
    # title: Как слушать чужую речь
    # author: Кто-то
    # audio: tracks/my_track.mp3
    # language: en
    # translation: ru
    0:00 Hello|Привет there|там
    0:05 This line has no translations yet
    1:23.5 Точность до долей секунды — тоже можно

Слово с переводом пишется как слово|перевод. Слово без перевода остаётся
без него: артикль или связку переводить нечем, и пустая строка под ним
честнее выдуманного слова.

ЗАПУСК:
    python3 tools/split_track.py путь/к/файлу.txt
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "tracks")

HEADER = re.compile(r"^#\s*(\w+)\s*:\s*(.+?)\s*$")
STAMP = re.compile(r"^(?:(\d+):)?(\d+)(?:[.,](\d{1,3}))?\s+(.*)$")

REQUIRED = ("id", "audio")


def parse_stamp(minutes, seconds, fraction):
    total = int(seconds) * 1000
    if minutes:
        total += int(minutes) * 60_000
    if fraction:
        total += int(fraction.ljust(3, "0"))
    return total


def parse(path):
    meta = {}
    lines = []
    with open(path, encoding="utf-8") as handle:
        for number, raw in enumerate(handle, 1):
            raw = raw.rstrip("\n")
            if not raw.strip():
                continue
            header = HEADER.match(raw)
            if header:
                meta[header.group(1).lower()] = header.group(2)
                continue
            stamp = STAMP.match(raw.strip())
            if not stamp:
                raise SystemExit(
                    f"строка {number}: не понял — ждал «0:05 текст» или «# ключ: значение»\n  {raw}"
                )
            start = parse_stamp(stamp.group(1), stamp.group(2), stamp.group(3))
            tokens = [t for t in stamp.group(4).split() if t]
            if not tokens:
                raise SystemExit(f"строка {number}: время есть, текста нет")
            lines.append((start, tokens))

    missing = [key for key in REQUIRED if key not in meta]
    if missing:
        raise SystemExit(f"в шапке не хватает: {', '.join('# ' + m for m in missing)}")
    if not lines:
        raise SystemExit("в файле нет ни одной строки с текстом")

    # Время строк обязано расти. Перепутанный порядок сломал бы поиск
    # активного слова (он двоичный) молча и неочевидно — лучше сказать сразу.
    for i in range(1, len(lines)):
        if lines[i][0] <= lines[i - 1][0]:
            raise SystemExit(
                f"время идёт назад: {lines[i - 1][0]} мс, потом {lines[i][0]} мс"
            )
    return meta, lines


def split_line(start, end, tokens):
    """Делит строку между словами пропорционально длине в буквах."""
    words = []
    for token in tokens:
        text, _, translation = token.partition("|")
        words.append((text, translation.strip() or None))

    weights = [max(1, len(text)) for text, _ in words]
    total = sum(weights)
    span = max(1, end - start)

    out = []
    cursor = start
    for index, ((text, translation), weight) in enumerate(zip(words, weights)):
        share = round(span * weight / total)
        stop = end if index == len(words) - 1 else min(end, cursor + share)
        out.append(
            {
                "w": text,
                "t": translation,
                "start": cursor,
                # Слово не может кончиться раньше, чем началось.
                "end": stop if stop > cursor else cursor + 1,
            }
        )
        cursor = out[-1]["end"]
    return out


def build(path):
    meta, lines = parse(path)

    # Конец последней строки знать неоткуда: следующей нет. Берём среднюю
    # длину строки — ошибка здесь стоит одной строки в конце, и это дешевле,
    # чем требовать от человека лишнее число.
    spans = [lines[i + 1][0] - lines[i][0] for i in range(len(lines) - 1)]
    tail = round(sum(spans) / len(spans)) if spans else 3000

    out_lines = []
    for index, (start, tokens) in enumerate(lines):
        end = lines[index + 1][0] if index + 1 < len(lines) else start + tail
        out_lines.append(split_line(start, end, tokens))

    track = {
        "id": meta["id"],
        "title": meta.get("title", meta["id"]),
        "author": meta.get("author", ""),
        "audio": meta["audio"],
        "language": meta.get("language", "en"),
        "translation": meta.get("translation", "ru"),
        "lines": out_lines,
    }

    os.makedirs(OUT_DIR, exist_ok=True)
    target = os.path.join(OUT_DIR, f"{meta['id']}.json")
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(track, handle, ensure_ascii=False, indent=1)

    # Список треков — тот же файл, что читает игра. Дописываем, а не
    # перезаписываем: рядом лежат чужие треки.
    index_path = os.path.join(OUT_DIR, "index.json")
    ids = []
    if os.path.exists(index_path):
        with open(index_path, encoding="utf-8") as handle:
            ids = json.load(handle)
    ids = [row for row in ids if row != meta["id"]]
    ids.append(meta["id"])
    with open(index_path, "w", encoding="utf-8") as handle:
        json.dump(ids, handle, ensure_ascii=False, indent=1)

    words = [word for line in out_lines for word in line]
    untranslated = sum(1 for word in words if not word["t"])
    print(f"{target}")
    print(f"  строк: {len(out_lines)}, слов: {len(words)}")
    print(f"  без перевода: {untranslated}")
    print(f"  длительность разметки: {words[-1]['end'] / 1000:.1f} с")
    print(f"  звук должен лежать в assets/{meta['audio']}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    build(sys.argv[1])
