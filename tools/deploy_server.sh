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
npx supabase db push

step "2/2 Деплою Edge Functions"
# evaluate-recording — воркер оценки; config-check — диагностика ключей;
# synthesize-speech — озвучка разбора (Google Text-to-Speech).
npx supabase functions deploy evaluate-recording
npx supabase functions deploy config-check
npx supabase functions deploy synthesize-speech

note "Сервер обновлён до $(git rev-parse --short HEAD)."
