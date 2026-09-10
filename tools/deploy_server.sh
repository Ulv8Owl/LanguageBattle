#!/usr/bin/env bash
#
# Серверная часть: миграции и Edge Functions. Обычно вызывается из
# ./tools/release.sh, но можно и отдельно: ./tools/deploy_server.sh [ветка]
#
# Порядок внутри важен: сначала база, потом функции. Функция, задеплоенная
# раньше своей миграции, будет писать в столбец, которого ещё нет.

set -euo pipefail
BRANCH="${1:-features}"
cd "$(dirname "$0")/.."
# shellcheck source=tools/lib.sh
source tools/lib.sh

step "0/2 Проверяю, что на диске лежит актуальный код"
require_clean_tree
require_synced "$BRANCH"
note "Деплою $(git rev-parse --short HEAD)  $(git log -1 --format=%s)"

step "1/2 Применяю миграции"
# --include-all нужен из-за веток сравнения, и вот почему.
#
# У Omni своя миграция (0047), у LLM своя (0048), и в папке каждой ветки
# лежит только СВОЯ. База же одна на всех. Стоит применить 0048 с ветки LLM,
# а потом перейти на Omni — и CLI видит местный файл 0047, которого в базе
# нет, а номер у него МЕНЬШЕ последнего применённого. Без флага он на этом
# останавливается с малопонятным «found local migration files to be inserted
# before the last migration on remote database».
#
# Флаг говорит: применяй всё, чего в базе ещё нет, независимо от номера. Для
# наших миграций это безопасно — они только добавляют колонки, и все через
# `if not exists`. Ничего чужого ни одна ветка не сносит: обе колонки Omni и
# LLM спокойно живут в базе рядом.
npx supabase db push --include-all

step "2/2 Деплою Edge Functions"
# evaluate-recording — воркер оценки; config-check — диагностика ключей;
# synthesize-speech — озвучка разбора (Google Text-to-Speech).
npx supabase functions deploy evaluate-recording
npx supabase functions deploy config-check
npx supabase functions deploy synthesize-speech

note "Сервер обновлён до $(git rev-parse --short HEAD)."
