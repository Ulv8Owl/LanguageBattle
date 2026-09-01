"""Общие функции для tools/build_content.py и tools/split_content.py.

Формат исходников содержимого (content/<язык>/phrases_<уровень>.txt и
content/<язык>/words_<уровень>.txt): одна фраза или одно слово на строку,
в порядке, СОВПАДАЮЩЕМ С АНГЛИЙСКИМ ФАЙЛОМ ТОГО ЖЕ УРОВНЯ — строка N
любого языка это перевод строки N английского. Порядок и есть ключ
соответствия, отдельного id нет: добавить фразу значит дописать строку в
конец файла на ВСЕХ языках уровня сразу, а не только на одном.

Ничего не знает про JSON — только читает/пишет построчный текст и считает
строки. JSON собирает build_content.py.
"""

from __future__ import annotations

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTENT_ROOT = REPO_ROOT / "content"
LEVELS = ["a1", "a2", "b1", "b2", "c1", "c2"]

# Английский — канонический порядок и обязательный счётчик строк для
# любого уровня. Не потому что он "главный" язык игры, а потому что он
# гарантированно существует для всех шести уровней уже сегодня — у любого
# другого языка на C2, например, файла может и не быть вовсе.
CANONICAL_LANGUAGE = "en"


class ContentError(Exception):
    """Ошибка в исходниках контента — несовпадение числа строк, пустая
    строка внутри файла и т.п. Всегда останавливает сборку: тихо
    подставить не то слово на 37-й позиции хуже, чем упасть с понятной
    причиной."""


def read_lines(path: pathlib.Path) -> list[str]:
    """Строки файла, без завершающих переносов, БЕЗ ОДНОЙ (максимум)
    завершающей пустой строки — её оставляют текстовые редакторы,
    сохраняющие файл с финальным \\n, и это не пропущенная фраза.

    Пустая строка ГДЕ УГОДНО ВНУТРИ файла — ошибка: она означает разрыв
    построчного соответствия с английским для всех строк после неё.
    """
    raw = path.read_text(encoding="utf-8").split("\n")
    if raw and raw[-1] == "":
        raw = raw[:-1]
    for i, line in enumerate(raw):
        if line.strip() == "":
            raise ContentError(
                f"{path}: пустая строка на позиции {i + 1} — она сдвинула бы "
                "соответствие с английским для всех фраз после неё"
            )
    return raw


def language_dirs() -> list[pathlib.Path]:
    if not CONTENT_ROOT.is_dir():
        return []
    return sorted(p for p in CONTENT_ROOT.iterdir() if p.is_dir())


def content_file(language: str, kind: str, level: str) -> pathlib.Path:
    """kind — 'phrases' или 'words'."""
    return CONTENT_ROOT / language / f"{kind}_{level}.txt"
