#!/usr/bin/env python3
"""Проверка перевода методом обратного перевода (back-translation).

Смысл метода: берём фразу на английском, переводим на целевой язык (это
уже сделано — она лежит в content/<lang>/...), затем ПЕРЕВОДИМ ЕЁ ОБРАТНО
на английский (любым переводчиком — вручную, через GPT, через API — этот
скрипт не переводит, он только СРАВНИВАЕТ). Если исходная английская фраза
и обратный перевод означают одно и то же — прямой перевод, скорее всего,
верный. Схожесть смысла измеряется косинусной близостью эмбеддингов
многоязычной модели (sentence-transformers).

Пороги (заданы как договорились):
  зелёный  >= 0.85  — принимать как есть, дальше не проверять
  жёлтый   0.75-0.85 — сомнительно, стоит перегенерировать/перепроверить руками
  красный  <  0.75  — обязательная ручная проверка

ВАЖНО — как запускать (НЕ вставляй код ниже прямо в bash построчно, это
питон-скрипт, его нужно вызывать через python3):

    # 1. Активировать venv (в каждом новом окне терминала заново):
    source venv/bin/activate

    # 2. Запустить, передав ДВА ПОСТРОЧНО СООТВЕТСТВУЮЩИХ файла —
    #    оригинал и обратный перевод (тот же порядок строк, то же их число):
    python3 tools/verify_translation.py \\
        content/en/phrases_a1.txt \\
        /tmp/es_back_to_en.txt \\
        --lang es

    # 3. Деактивировать venv, когда закончил (необязательно):
    deactivate

Первый запуск скачает модель (пара сотен МБ) в ~/.cache/huggingface —
нужен интернет один раз, дальше модель работает офлайн.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

MODELS = {
    "labse": "sentence-transformers/LaBSE",
    "multilingual-e5-large": "intfloat/multilingual-e5-large",
    "bge-m3": "BAAI/bge-m3",
}


def read_lines(path: Path) -> list[str]:
    raw = path.read_text(encoding="utf-8").split("\n")
    if raw and raw[-1] == "":
        raw = raw[:-1]
    return raw


def load_model(name: str):
    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        print(
            "sentence-transformers не найден. Похоже, venv не активирован — "
            "выполни сначала:\n\n    source venv/bin/activate\n\n"
            "и запусти команду заново.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    model_id = MODELS[name]
    print(f"загружаю модель {model_id} (при первом разе — скачивание)...", file=sys.stderr)
    return SentenceTransformer(model_id)


def zone(score: float, yellow: float, green: float) -> str:
    if score >= green:
        return "зелёный"
    if score >= yellow:
        return "жёлтый"
    return "красный"


ANSI = {"зелёный": "\033[32m", "жёлтый": "\033[33m", "красный": "\033[31m"}
RESET = "\033[0m"


def colorize(text: str, z: str, enabled: bool) -> str:
    return f"{ANSI[z]}{text}{RESET}" if enabled else text


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("original", type=Path, help="исходный английский файл (построчно)")
    parser.add_argument(
        "back_translated", type=Path, help="файл с обратным переводом на английский (построчно, тот же порядок)"
    )
    parser.add_argument("--lang", default=None, help="код проверяемого языка — только для заголовка отчёта")
    parser.add_argument(
        "--model",
        choices=sorted(MODELS),
        default="labse",
        help="модель эмбеддингов (по умолчанию LaBSE — лучше всего покрывает 100+ языков)",
    )
    parser.add_argument("--green", type=float, default=0.85, help="порог зелёной зоны (по умолчанию 0.85)")
    parser.add_argument("--yellow", type=float, default=0.75, help="порог жёлтой зоны (по умолчанию 0.75)")
    parser.add_argument(
        "--only-flagged",
        action="store_true",
        help="в отчёте показать только жёлтые/красные строки (зелёные пропустить)",
    )
    parser.add_argument(
        "--export-flagged",
        type=Path,
        default=None,
        help="сохранить только жёлтые/красные строки (номер + обе фразы) в отдельный файл для разбора",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="не подсвечивать зоны цветом (по умолчанию цвет включён в терминале и выключен при перенаправлении в файл)",
    )
    args = parser.parse_args()
    color = sys.stdout.isatty() and not args.no_color

    if not args.original.exists():
        print(f"нет файла {args.original}", file=sys.stderr)
        return 1
    if not args.back_translated.exists():
        print(f"нет файла {args.back_translated}", file=sys.stderr)
        return 1

    originals = read_lines(args.original)
    back = read_lines(args.back_translated)
    if len(originals) != len(back):
        print(
            f"ОСТАНОВ: в {args.original} — {len(originals)} строк, а в {args.back_translated} — {len(back)}. "
            "Файлы должны построчно соответствовать друг другу.",
            file=sys.stderr,
        )
        return 1

    model = load_model(args.model)
    emb_orig = model.encode(originals, convert_to_tensor=True, show_progress_bar=False)
    emb_back = model.encode(back, convert_to_tensor=True, show_progress_bar=False)

    from sentence_transformers import util

    scores = util.cos_sim(emb_orig, emb_back).diagonal().tolist()

    counts = {"зелёный": 0, "жёлтый": 0, "красный": 0}
    flagged: list[str] = []
    label = f" ({args.lang})" if args.lang else ""
    print(f"\nПроверка обратным переводом{label} — модель {args.model}, {len(originals)} строк\n")

    for i, (orig, bt, score) in enumerate(zip(originals, back, scores), start=1):
        z = zone(score, args.yellow, args.green)
        counts[z] += 1
        if z != "зелёный":
            flagged.append(f"{i}\t{score:.3f}\t{orig}\t{bt}")
        if args.only_flagged and z == "зелёный":
            continue
        line = f"[{i:>4}] {score:.3f} {z:<7} ориг: {orig}"
        print(colorize(line, z, color))
        print(colorize(f"           обратно: {bt}", z, color))

    total = len(originals)
    summary = (
        colorize(f"зелёных {counts['зелёный']}/{total}", "зелёный", color)
        + ", "
        + colorize(f"жёлтых {counts['жёлтый']}/{total}", "жёлтый", color)
        + ", "
        + colorize(f"красных {counts['красный']}/{total}", "красный", color)
    )
    print(f"\nИтого: {summary}")

    if args.export_flagged and flagged:
        args.export_flagged.write_text(
            "номер\tсходство\tоригинал\tобратный_перевод\n" + "\n".join(flagged) + "\n",
            encoding="utf-8",
        )
        print(f"жёлтые/красные строки сохранены в {args.export_flagged}")

    return 1 if counts["красный"] > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
