#!/usr/bin/env python3
"""Собирает assets/phrases/phrases_<уровень>.json и
assets/vocab/words_<уровень>.json из content/<язык>/*.txt.

ЭТО ЕДИНСТВЕННЫЙ СПОСОБ ПРАВИТЬ assets/*.json — их саму руками не
трогают, их перезаписывает этот скрипт. Формат-приёмник (JSON, ключи —
коды языков, значения — фраза/слово) не поменялся: RemoteContent,
PhraseBank и FlashcardBank на клиенте ничего не знают про content/ вообще
и продолжают читать assets/*.json как раньше.

Что проверяется перед сборкой, а не после:
  * у английского файла есть все шесть уровней — без него не с чем
    сверять число строк у остальных языков;
  * ЧИСЛО СТРОК языка на уровне РОВНО СОВПАДАЕТ с английским. Инвариант,
    на который полагаются PhraseBank.hasContentFor/FlashcardBank.
    hasContentFor (весь уровень переведён или ни одной строки) —
    здесь он не «соблюдается», а физически не может быть нарушен: файл с
    неверным числом строк заворачивает сборку целиком, а не какую-то
    одну фразу;
  * ни одной пустой строки внутри файла (content_lib.read_lines).

Запуск:
    python3 tools/build_content.py           # собрать всё
    python3 tools/build_content.py --check   # ничего не писать, только
                                              # сообщить, разошлось ли
                                              # content/ и assets/ (для CI/
                                              # предкоммитной проверки)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from content_lib import (
    CANONICAL_LANGUAGE,
    CONTENT_ROOT,
    LEVELS,
    REPO_ROOT,
    ContentError,
    content_file,
    language_dirs,
    read_lines,
)


def build_one(kind: str, level: str) -> tuple[str, list[dict[str, str]]] | None:
    canonical_path = content_file(CANONICAL_LANGUAGE, kind, level)
    if not canonical_path.exists():
        return None
    canonical_lines = read_lines(canonical_path)
    expected = len(canonical_lines)

    per_language: dict[str, list[str]] = {CANONICAL_LANGUAGE: canonical_lines}
    for lang_dir in language_dirs():
        lang = lang_dir.name
        if lang == CANONICAL_LANGUAGE:
            continue
        path = content_file(lang, kind, level)
        if not path.exists():
            continue
        lines = read_lines(path)
        if len(lines) != expected:
            raise ContentError(
                f"{path}: {len(lines)} строк, а в {canonical_path.relative_to(REPO_ROOT)} — {expected}. "
                "Число строк ОБЯЗАНО совпадать: строка N любого языка — перевод строки N английского."
            )
        per_language[lang] = lines

    entries = [
        {lang: lines[i] for lang, lines in per_language.items()}
        for i in range(expected)
    ]
    out_dir = REPO_ROOT / ("assets/phrases" if kind == "phrases" else "assets/vocab")
    out_name = f"{'phrases' if kind == 'phrases' else 'words'}_{level}.json"
    return str(out_dir / out_name), entries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="не писать файлы — только сообщить, актуальны ли assets/*.json",
    )
    args = parser.parse_args()

    if not CONTENT_ROOT.is_dir():
        print(f"нет каталога {CONTENT_ROOT} — нечего собирать", file=sys.stderr)
        return 1

    stale: list[str] = []
    try:
        for kind in ("phrases", "words"):
            for level in LEVELS:
                result = build_one(kind, level)
                if result is None:
                    continue
                out_path, entries = result
                # Формат сериализации СОЗНАТЕЛЬНО совпадает с тем, что уже
                # лежит в assets/ (json.dumps со стандартными разделителями,
                # без переносов) — иначе --check считал бы файл устаревшим
                # при каждом запуске просто из-за разницы в отступах.
                new_text = json.dumps(entries, ensure_ascii=False) + "\n"
                langs = sorted(entries[0].keys())

                out = Path(out_path)
                old_text = out.read_text(encoding="utf-8") if out.exists() else None
                changed = old_text != new_text

                if args.check:
                    if changed:
                        stale.append(str(out.relative_to(REPO_ROOT)))
                    continue

                out.write_text(new_text, encoding="utf-8")
                mark = "обновлён" if changed else "без изменений"
                print(f"{out.relative_to(REPO_ROOT)}: {len(entries)} записей, языки {langs} — {mark}")
    except ContentError as e:
        print(f"ОСТАНОВ: {e}", file=sys.stderr)
        return 1

    if args.check:
        if stale:
            print("Устарели (нужно запустить tools/build_content.py и закоммитить результат):")
            for path in stale:
                print(f"  {path}")
            return 1
        print("assets/*.json актуальны относительно content/.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
