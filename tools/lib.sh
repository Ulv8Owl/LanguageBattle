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
  [ "$head" = "$remote" ] && return 0

  local ahead behind elsewhere advice
  ahead="$(git rev-list --count "origin/$branch..HEAD")"
  behind="$(git rev-list --count "HEAD..origin/$branch")"

  # Самый частый и самый непонятный случай: человек стоит на одной ветке, а
  # подтянул в неё чужую (`git pull origin другая-ветка`). Коммиты при этом
  # никуда не делись и лежат на origin/другая-ветка — но выглядит это как
  # «моя ветка обогнала origin на пять коммитов», и совет «запушь их» здесь
  # ровно противоположен правильному. Поэтому сначала проверяем, не лежит ли
  # текущий HEAD целиком на какой-то другой ветке origin.
  elsewhere="$(git branch --remotes --contains HEAD --format='%(refname:short)' 2>/dev/null \
    | grep -v "^origin/$branch\$" | grep -v '^origin/HEAD' | head -1)"

  if [ -n "$elsewhere" ] && [ "$behind" = "0" ]; then
    advice="Твои $ahead коммит(ов) целиком лежат на ${elsewhere} — похоже, ты просто
не на ту ветку встал: сделал 'git pull origin ${elsewhere#origin/}', стоя на '$branch'.
Ничего не потеряно, всё уже на origin. Разложить по местам:

  git checkout -B ${elsewhere#origin/} $elsewhere
  git branch -f $branch origin/$branch

Первая строка ставит тебя на нужную ветку, вторая возвращает '$branch' на место."
  elif [ "$behind" = "0" ]; then
    advice="У тебя $ahead локальных коммит(ов), которых нет на origin/$branch.
Запушь их: git push -u origin $branch"
  elif [ "$ahead" = "0" ]; then
    advice="Отстаёшь на $behind коммит(ов). Запусти ./tools/release.sh $branch —
он синхронизирует и сделает всё по порядку."
  else
    advice="Ветки разошлись: $ahead своих коммит(ов), $behind чужих.
Посмотри свои: git log --oneline origin/$branch..HEAD"
  fi

  fail "рабочее дерево не совпадает с origin/$branch.
  на диске:  $(git rev-parse --short HEAD)  $(git log -1 --format=%s)
  на origin: $(git rev-parse --short "origin/$branch")  $(git log -1 --format=%s "origin/$branch")

$advice"
}
