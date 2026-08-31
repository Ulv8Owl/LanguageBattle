# Общие проверки для скриптов сборки и деплоя. Подключается через `source`.

step() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }
note() { printf '\033[1;32m%s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mОСТАНОВ: %s\033[0m\n' "$1" >&2; exit 1; }

require_clean_tree() {
  if [ -n "$(git status --porcelain)" ]; then
    git status --short
    fail "рабочее дерево грязное. Сначала закоммить или отбрось эти правки —
иначе переключение ветки не пройдёт, а собрано будет непонятно что."
  fi
}

# Ветка, на которой сейчас стоит рабочее дерево. Это и есть умолчание для
# всех трёх скриптов: без аргумента человек имеет в виду «выложи то, что у
# меня сейчас на диске», а не какую-то конкретную ветку.
#
# Раньше здесь было жёстко зашито "features", и работа на второй ветке
# упиралась в отказ «дерево не совпадает с origin/features» — сообщение
# верное, но не про ту ветку, и человек шёл искать несуществующее
# расхождение.
current_branch() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$branch" = "HEAD" ]; then
    fail "HEAD отделён от веток (detached HEAD) — непонятно, что выкладывать.
Перейди на ветку: git checkout <ветка> — или назови её аргументом."
  fi
  printf '%s' "$branch"
}

# Дерево ДОЛЖНО совпадать с origin. Существует потому, что `git fetch` только
# скачивает историю и НЕ трогает файлы: после него на диске лежит прежний код,
# а deploy деплоит именно файлы с диска. Один раз это уже стоило целого круга
# «задеплоил, собрал, ничего не изменилось» — сервер тогда получил старые
# функции, и найти это можно было только по датам коммитов.
require_synced() {
  local branch="$1"
  git fetch --quiet origin "$branch" \
    || fail "не удалось получить origin/$branch.
Если ветки на origin ещё нет — сначала запушь её: git push -u origin $branch"
  local head remote
  head="$(git rev-parse HEAD)"
  remote="$(git rev-parse "origin/$branch")"
  if [ "$head" != "$remote" ]; then
    fail "рабочее дерево не совпадает с origin/$branch.
  на диске:  $(git rev-parse --short HEAD)  $(git log -1 --format=%s)
  на origin: $(git rev-parse --short "origin/$branch")  $(git log -1 --format=%s "origin/$branch")
Запусти ./tools/release.sh $branch — он синхронизирует и сделает всё по порядку."
  fi
}
