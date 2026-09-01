#!/usr/bin/env python3
"""Разовая миграция: assets/phrases/*.json и assets/vocab/*.json (сейчас —
единственные файлы, где en/ru/es перемешаны построчно в одном JSON) в
content/<язык>/{phrases,words}_<уровень>.txt.

Запускается ОДИН РАЗ, чтобы завести новую структуру из уже существующего
контента. После неё источником правды становится content/ — dальнейшие
правки вносятся туда, а assets/*.json пересобирает tools/build_content.py.
Повторный запуск безопасен (перезапишет content/ тем же содержимым assets/
— если assets/ с тех пор не трогали руками, ничего не изменится), но
предназначен не для этого.

Запуск:
    python3 tools/split_content.py
"""

from __future__ import annotations

import json

from content_lib import CONTENT_ROOT, LEVELS, REPO_ROOT, content_file


def split_one(kind: str, level: str) -> None:
    src = REPO_ROOT / ("assets/phrases" if kind == "phrases" else "assets/vocab")
    filename = f"{'phrases' if kind == 'phrases' else 'words'}_{level}.json"
    entries = json.loads((src / filename).read_text(encoding="utf-8"))

    languages = set()
    for entry in entries:
        languages.update(entry.keys())

    for lang in sorted(languages):
        lines = [entry[lang] for entry in entries]
        out = content_file(lang, kind, level)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"  {out.relative_to(REPO_ROOT)}: {len(lines)} строк")


def main() -> None:
    CONTENT_ROOT.mkdir(exist_ok=True)
    for level in LEVELS:
        print(f"уровень {level}:")
        split_one("phrases", level)
        split_one("words", level)
    print("\nГотово. Дальше правь файлы в content/, а не assets/*.json —")
    print("assets/*.json теперь СОБИРАЕМЫЙ файл, tools/build_content.py его перезапишет.")


if __name__ == "__main__":
    main()
