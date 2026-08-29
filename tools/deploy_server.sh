#!/usr/bin/env bash
#
# Серверная часть: миграции и Edge Functions. ./tools/deploy_server.sh
#
# Отдельно от сборки приложения, потому что порядок важен: сначала база,
# потом функции, и только потом APK. Функция, задеплоенная раньше своей
# миграции, будет писать в столбец, которого ещё нет.

set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }

step "1/2 Применяю миграции"
npx supabase db push

step "2/2 Деплою Edge Functions"
# evaluate-recording — воркер оценки; config-check — диагностика ключей.
npx supabase functions deploy evaluate-recording
npx supabase functions deploy config-check

printf '\n\033[1;32mСервер обновлён. Теперь можно собирать APK: ./tools/build.sh features\033[0m\n'
