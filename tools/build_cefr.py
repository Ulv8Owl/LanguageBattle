#!/usr/bin/env python3
"""Собирает банк фраз и разборы из assets/cefr.

ИСТОЧНИК:

    assets/cefr/phrases/<LANG>/phrases_<LEVEL>.txt          18 файлов
    assets/cefr/explanations/<РОДНОЙ>-<ЦЕЛЕВОЙ>/explanations_<LEVEL>.txt   36

Формат описан в assets/cefr/README.md и проверяется assets/cefr/validate.py;
здесь он только читается.

ПОЯСНЕНИЯ РАЗЛОЖЕНЫ ПО ПАРАМ, А НЕ ПО ЯЗЫКАМ. Разбор обязан знать сразу
две вещи: на каком языке его читать (родной язык игрока) и про какой язык
он вообще (тот, который игрок учит). Прошлая версия датасета знала только
второе — и потому игроку с парой ru→en показывала разбор русской
формулировки «в семь» вместо английской "at seven". Каталог называется
РОДНОЙ-ЦЕЛЕВОЙ, в том же порядке, в каком пара задана у игрока.

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

Пояснения выкладываются ОТДЕЛЬНЫМИ файлами на пару и уровень:

    assets/phrases/explain_<уровень>_<родной>-<целевой>.json

    [ ["разбор 1.1", "разбор 1.2", ...], ... ]   // 10 фраз, по элементам

Отдельными — потому что игроку нужна ровно одна пара из шести, а всё
вместе это больше мегабайта. Класть шесть пар в общий cefr_<уровень>.json
значило бы качать в шесть раз больше ради того же экрана.

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
# Пары «родной-целевой»: все шесть сочетаний трёх языков. Разбор одной и
# той же английской формы для русскоговорящего и для испаноговорящего —
# это два разных текста, а не один переведённый: ошибаются они по разным
# причинам, и объяснять надо именно причину.
PAIRS = [(n, t) for n in LANGUAGES for t in LANGUAGES if n != t]

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

# Строка пояснения: «<фраза>.<элемент> «<якорь>» — <разбор>». Якорь —
# текст элемента целевого языка; он служебный и до игрока не доезжает,
# зато позволяет сверить, что разбор не уехал на соседний кусок.
EXPLANATION_RE = re.compile(r"^(\d+)\.(\d+) «(.+?)» — (.+)$")


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


def load_explanations(level: str, native: str, target: str,
                      target_elements: list[list[dict[str, str]]]) -> list[list[str]]:
    """Пояснения пары для уровня: [фраза][элемент] -> текст разбора.

    Якорь в «ёлочках» сверяется с элементом ЦЕЛЕВОГО языка посимвольно и в
    результат не попадает: игрок видит текст элемента в заголовке разбора,
    и второй раз он там не нужен. Расхождение якоря — остановка сборки:
    разбор, уехавший на соседний элемент, на экране неотличим от верного.
    """
    path = (SOURCE_DIR / "explanations" / f"{native.upper()}-{target.upper()}"
            / f"explanations_{level}.txt")
    lines = read_lines(path)
    elements = ELEMENTS_PER_LEVEL[level]
    table: list[list[str | None]] = [[None] * elements for _ in range(PHRASES_PER_LEVEL)]

    for i, line in enumerate(lines, start=1):
        m = EXPLANATION_RE.match(line)
        if not m:
            raise SourceError(f"{path.name}:{i}: строка не по формату «N.M «элемент» — разбор»")
        phrase_no, element_no = int(m.group(1)), int(m.group(2))
        anchor, body = m.group(3), m.group(4).strip()
        if not (1 <= phrase_no <= PHRASES_PER_LEVEL):
            raise SourceError(f"{path.name}:{i}: номер фразы {phrase_no} вне 1..{PHRASES_PER_LEVEL}")
        if not (1 <= element_no <= elements):
            raise SourceError(f"{path.name}:{i}: номер элемента {element_no} вне 1..{elements}")
        if table[phrase_no - 1][element_no - 1] is not None:
            raise SourceError(f"{path.name}:{i}: пояснение {phrase_no}.{element_no} уже было")
        if not body:
            raise SourceError(f"{path.name}:{i}: пустой разбор")
        actual = target_elements[phrase_no - 1][element_no - 1]["text"]
        if anchor != actual:
            raise SourceError(
                f"{path.name}:{i}: якорь «{anchor}» не совпадает с элементом "
                f"{phrase_no}.{element_no} языка {target}: «{actual}»"
            )
        table[phrase_no - 1][element_no - 1] = body

    for p_i in range(PHRASES_PER_LEVEL):
        for e_i in range(elements):
            if table[p_i][e_i] is None:
                raise SourceError(f"{path.name}: нет пояснения {p_i + 1}.{e_i + 1}")
    return table  # type: ignore[return-value]


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


def build_explanations(level: str) -> dict[str, list[list[str]]]:
    """Пояснения всех шести пар уровня: «родной-целевой» -> [фраза][элемент]."""
    by_pair: dict[str, list[list[str]]] = {}
    target_cache: dict[str, list[list[dict[str, str]]]] = {}
    for native, target in PAIRS:
        if target not in target_cache:
            target_cache[target], _ = load_phrases(level, target)
        by_pair[f"{native}-{target}"] = load_explanations(
            level, native, target, target_cache[target])
    return by_pair


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="не писать файлы, только сообщить, актуальны ли они")
    args = parser.parse_args()

    stale: list[str] = []

    def emit(out: Path, payload: object, note: str) -> None:
        """Записать JSON или, в режиме --check, отметить устаревшим."""
        new_text = json.dumps(payload, ensure_ascii=False) + "\n"
        old_text = out.read_text(encoding="utf-8") if out.exists() else None
        changed = old_text != new_text
        if args.check:
            if changed:
                stale.append(str(out.relative_to(REPO_ROOT)))
            return
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(new_text, encoding="utf-8")
        print(f"{out.relative_to(REPO_ROOT)}: {note} — "
              f"{'обновлён' if changed else 'без изменений'}")

    try:
        for level in LEVELS:
            phrases = build_level(level)
            emit(OUT_DIR / f"cefr_{level.lower()}.json", phrases,
                 f"{len(phrases)} фраз по {ELEMENTS_PER_LEVEL[level]} элементов")

            for pair, table in build_explanations(level).items():
                emit(OUT_DIR / f"explain_{level.lower()}_{pair}.json", table,
                     f"{sum(len(row) for row in table)} пояснений")
    except SourceError as e:
        print(f"ОСТАНОВ: {e}", file=sys.stderr)
        return 1

    if args.check:
        if stale:
            print("Устарели (запусти tools/build_cefr.py и закоммить результат):")
            for path in stale:
                print(f"  {path}")
            return 1
        print("assets/phrases/*.json актуальны относительно assets/cefr/.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
