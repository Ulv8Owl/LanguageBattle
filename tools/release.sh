#!/usr/bin/env bash
#
# Единственная команда полного круга: ./tools/release.sh [ветка]
#
#   синхронизация -> миграции -> Edge Functions -> APK -> установка
#
# Порядок здесь не пожелание, а требование: `git fetch` не меняет файлы на
# диске, а деплой берёт именно их. Один раз из-за этого сервер получил старые
# функции, приложение — новые, и полдня ушло на поиск несуществующей ошибки.

set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/lib.sh
source tools/lib.sh
# Без аргумента — та ветка, что сейчас на диске.
BRANCH="${1:-$(current_branch)}"

step "Синхронизирую $BRANCH"
require_clean_tree
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git merge --ff-only "origin/$BRANCH" \
  || fail "локальная $BRANCH разошлась с origin/$BRANCH.
Посмотри свои коммиты: git log --oneline origin/$BRANCH..HEAD"
note "На $(git rev-parse --short HEAD)  $(git log -1 --format=%s)"

# Мы только что могли обновить сами себя. Bash читает файл скрипта по мере
# выполнения, и продолжать после git-обновления значит выполнять смесь старой
# и новой версии — ровно поэтому первый запуск после правки скриптов
# отрабатывал по-старому и молча делал не то. Перезапускаемся один раз.
if [ -z "${RELEASE_REEXEC:-}" ]; then
  export RELEASE_REEXEC=1
  note "Перезапускаю себя уже обновлённым"
  exec bash "$0" "$BRANCH"
fi

./tools/deploy_server.sh "$BRANCH"
./tools/build.sh "$BRANCH"
