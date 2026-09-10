#!/usr/bin/env bash
#
# ОДНА КОМАНДА НА ВСЁ: ./tools/release.sh [ветка]
#
#   выбор ветки -> синхронизация с origin -> миграции -> Edge Functions
#   -> зависимости -> проверка кода -> APK -> установка на телефон
#
# Без аргумента спрашивает ветку списком — помнить имена наизусть не нужно.
#
# ПОЧЕМУ ЭТО ОДИН СКРИПТ, А НЕ ДВА. Порядок здесь не пожелание, а требование.
# `git fetch` скачивает историю и НЕ трогает файлы на диске, а деплой берёт
# именно файлы. Один раз из-за этого сервер получил старые функции,
# приложение — новые, и полдня ушло на поиск несуществующей ошибки. Второй
# скрипт «для переключения веток» рядом с этим означал бы два места, где
# порядок должен совпадать, — и однажды они разойдутся.

set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/lib.sh
source tools/lib.sh

# Ветки проекта и чем они друг от друга отличаются. Список ровно для того,
# чтобы не приходилось помнить, где какая архитектура.
branch_note() {
  case "$1" in
    features) echo "основная разработка" ;;
    Omni)     echo "одна модель слушает запись целиком (qwen3-omni-flash / qwen3.5-omni-flash)" ;;
    LLM)      echo "распознавание речи + текстовый судья (дешевле, но записи не слышит)" ;;
    main)     echo "стабильная копия features" ;;
    *)        echo "" ;;
  esac
}
KNOWN_BRANCHES=(features Omni LLM main)

# --- Выбор ветки ------------------------------------------------------------
BRANCH="${1:-}"

if [ -z "$BRANCH" ]; then
  if [ ! -t 0 ]; then
    fail "не указана ветка. Запусти так:  ./tools/release.sh Omni
Доступны: ${KNOWN_BRANCHES[*]}"
  fi
  printf '\n\033[1;33mКакую ветку собрать?\033[0m\n\n'
  for i in "${!KNOWN_BRANCHES[@]}"; do
    printf '  %d) %-9s — %s\n' "$((i + 1))" "${KNOWN_BRANCHES[$i]}" "$(branch_note "${KNOWN_BRANCHES[$i]}")"
  done
  printf '\nНомер (или Enter, чтобы отменить): '
  read -r choice
  [ -n "$choice" ] || fail "ничего не выбрано — ничего и не делаю."
  case "$choice" in
    [1-9]*)
      BRANCH="${KNOWN_BRANCHES[$((choice - 1))]:-}"
      [ -n "$BRANCH" ] || fail "нет варианта с номером $choice."
      ;;
    *) BRANCH="$choice" ;;
  esac
fi

# Имя ветки с большой буквы, и это важно: git различает Omni и omni.
KNOWN=0
for b in "${KNOWN_BRANCHES[@]}"; do [ "$b" = "$BRANCH" ] && KNOWN=1; done
if [ "$KNOWN" = "0" ]; then
  SUGGEST=""
  for b in "${KNOWN_BRANCHES[@]}"; do
    [ "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$BRANCH" | tr '[:upper:]' '[:lower:]')" ] && SUGGEST="$b"
  done
  [ -n "$SUGGEST" ] && fail "ветки «$BRANCH» нет, а «$SUGGEST» есть — git различает большие и маленькие буквы.
Запусти:  ./tools/release.sh $SUGGEST"
  note "Ветка «$BRANCH» не из списка проекта — продолжаю, но проверь имя."
fi

step "1/4 Синхронизирую ветку $BRANCH"
echo "$(branch_note "$BRANCH")"
require_clean_tree

git fetch origin "$BRANCH" \
  || fail "не получилось скачать ветку с GitHub. Проверь интернет и доступ к репозиторию."
git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null \
  || fail "на GitHub нет ветки «$BRANCH». Есть: ${KNOWN_BRANCHES[*]}"

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git checkout "$BRANCH"
else
  # Первый переход на эту ветку с этого компьютера: локальной копии ещё нет.
  note "Ветки $BRANCH здесь ещё не было — создаю из origin/$BRANCH"
  git checkout -b "$BRANCH" "origin/$BRANCH"
fi

git merge --ff-only "origin/$BRANCH" \
  || fail "локальная $BRANCH разошлась с origin/$BRANCH — на этом компьютере есть
свои коммиты, которых нет на GitHub. Посмотри их:
  git log --oneline origin/$BRANCH..HEAD
Если они не нужны:  git reset --hard origin/$BRANCH"
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

step "2/4 Обновляю сервер под эту ветку"
# ВАЖНО: сервер один на все ветки. Edge Function, которая сейчас работает, —
# это та, что задеплоена последней. Двух архитектур одновременно не бывает:
# собрал Omni — сервер разбирает записи по Omni, и наоборот.
./tools/deploy_server.sh "$BRANCH"

step "3/4 Собираю и ставлю приложение"
./tools/build.sh "$BRANCH"

step "4/4 Готово"
cat <<EOF

────────────────────────────────────────────────
Ветка:  $BRANCH — $(branch_note "$BRANCH")
Коммит: $(git rev-parse --short HEAD)  $(git log -1 --format=%s)

Сервер и телефон теперь на одной и той же ветке. Чтобы перейти на другую,
запусти этот же скрипт с её именем — он сделает всё то же самое заново.
────────────────────────────────────────────────
EOF
