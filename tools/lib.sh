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

# Дерево ДОЛЖНО совпадать с origin. Существует потому, что `git fetch` только
# скачивает историю и НЕ трогает файлы: после него на диске лежит прежний код,
# а deploy деплоит именно файлы с диска. Один раз это уже стоило целого круга
# «задеплоил, собрал, ничего не изменилось» — сервер тогда получил старые
# функции, и найти это можно было только по датам коммитов.
require_synced() {
  local branch="$1"
  # Если ветки на GitHub нет, `git fetch` роняет скрипт голым «fatal:
  # couldn't find remote ref» — без единого слова о том, что делать. А
  # попасть сюда легко: достаточно запустить шаг, стоя на своей местной
  # ветке, которую ещё не отправляли.
  git fetch --quiet origin "$branch" 2>/dev/null || fail "на GitHub нет ветки «$branch».
Есть: $(remote_branches | tr '\n' ' ')
Если это твоя местная ветка — сначала отправь её:  git push -u origin $branch"

  local head remote here
  head="$(git rev-parse HEAD)"
  remote="$(git rev-parse "origin/$branch")"
  [ "$head" = "$remote" ] && return 0

  here="$(git rev-parse --abbrev-ref HEAD)"
  local extra=""
  [ "$here" != "$branch" ] && extra="
  И ты сейчас на ветке «$here», а не на «$branch»."

  fail "рабочее дерево не совпадает с origin/$branch.
  на диске:  $(git rev-parse --short HEAD)  $(git log -1 --format=%s)
  на origin: $(git rev-parse --short "origin/$branch")  $(git log -1 --format=%s "origin/$branch")$extra
Запусти ./tools/release.sh $branch — он синхронизирует и сделает всё по порядку,
в том числе если ветки разошлись."
}

# Ветки, которые ЕСТЬ на GitHub. Спрашиваем сам GitHub, а не список в скрипте:
# список в скрипте устаревает молча и потом предлагает собрать ветку, которой
# давно нет, а про нужную не говорит вовсе. Это уже случалось дважды.
remote_branches() {
  git ls-remote --heads origin 2>/dev/null | sed 's#.*refs/heads/##'
}

# ═══ СИНХРОНИЗАЦИЯ — ЕДИНСТВЕННОЕ МЕСТО, ГДЕ СКРИПТЫ ТРОГАЮТ ИСТОРИЮ ═══
#
# Здесь стоял простой `git merge --ff-only`, и на разошедшихся ветках он
# оставлял человека ровно там, откуда тот пришёл: «перемотка невозможна,
# сделай git reset --hard». То есть скрипт, обещающий сделать всё сам,
# упирался и отправлял чинить руками — а `deploy_server.sh` при этом
# советовал запустить как раз его. Совет ходил по кругу.
#
# Своими коммитами не распоряжаемся молча НИ В КАКОМ СЛУЧАЕ: они сначала
# уезжают в отдельную ветку и только потом пропадают из этой. Ничего не
# теряется, и вернуться к ним можно в любой момент.
sync_to_origin() {
  local branch="$1"

  git fetch origin "$branch" \
    || fail "не получилось скачать ветку с GitHub. Проверь интернет и доступ к репозиторию."
  git rev-parse --verify --quiet "origin/$branch" >/dev/null \
    || fail "на GitHub нет ветки «$branch». Есть: $(remote_branches | tr '\n' ' ')"

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git checkout "$branch" || fail "не получилось переключиться на $branch."
  else
    # Первый переход на эту ветку с этого компьютера: локальной копии ещё нет.
    note "Ветки $branch здесь ещё не было — создаю из origin/$branch"
    git checkout -b "$branch" "origin/$branch" || fail "не получилось создать $branch."
  fi

  # Чтобы `git pull` и `git status` дальше работали без аргументов. Без этого
  # git отвечает «у текущей ветки нет информации об отслеживании» — и человек
  # застревает на ровном месте.
  git branch --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1 || true

  local ahead behind
  ahead="$(git rev-list --count "origin/$branch..HEAD")"
  behind="$(git rev-list --count "HEAD..origin/$branch")"

  if [ "$ahead" = "0" ] && [ "$behind" = "0" ]; then
    note "Совпадает с origin/$branch"
    return 0
  fi

  if [ "$ahead" = "0" ]; then
    git merge --ff-only "origin/$branch" || fail "не получилось подтянуть origin/$branch."
    note "Подтянул $behind коммит(ов) с GitHub"
    return 0
  fi

  _resolve_own_commits "$branch" "$ahead" "$behind"
}

# Свои коммиты есть — решаем, что с ними, вместе с человеком.
_resolve_own_commits() {
  local branch="$1" ahead="$2" behind="$3"
  local backup="backup/$branch-$(date +%Y%m%d-%H%M%S)"

  printf '\n'
  if [ "$behind" = "0" ]; then
    note "На этом компьютере есть $ahead коммит(ов), которых нет на GitHub:"
  else
    note "Ветки разошлись: своих коммитов $ahead, чужих на GitHub $behind."
  fi
  git --no-pager log --oneline "origin/$branch..HEAD"
  printf '\n'

  if [ ! -t 0 ]; then
    fail "спросить некого — запущено не из терминала.
Свои коммиты (список выше) можно сохранить и встать на GitHub-версию так:
  git branch $backup
  git reset --hard origin/$branch
Они останутся в ветке $backup, и вернуться к ним можно когда угодно."
  fi

  if [ "$behind" = "0" ]; then
    printf '  1) Отправить их на GitHub (git push)\n'
    printf '  2) Отложить в ветку %s и встать на GitHub-версию\n' "$backup"
    printf '  3) Выйти и разобраться руками\n'
  else
    # Слияния здесь нет НАМЕРЕННО: конфликт бросил бы человека посреди
    # скрипта, в наполовину слитом дереве — ровно в то состояние, из
    # которого эти скрипты и существуют, чтобы не выходить.
    printf '  1) Отложить свои коммиты в ветку %s и встать на GitHub-версию\n' "$backup"
    printf '  2) Выйти и разобраться руками\n'
    printf '     (слить их с чужими — отдельная работа: git merge origin/%s)\n' "$branch"
  fi
  printf '\nНомер (или Enter, чтобы выйти): '
  read -r choice

  if [ "$behind" = "0" ] && [ "$choice" = "1" ]; then
    git push -u origin "$branch" || fail "push не прошёл — смотри сообщение выше."
    note "Отправлено на GitHub"
    return 0
  fi

  local reset_choice=1
  [ "$behind" = "0" ] && reset_choice=2
  if [ "$choice" = "$reset_choice" ]; then
    git branch "$backup" || fail "не получилось создать ветку $backup."
    git reset --hard "origin/$branch" || fail "не получилось встать на origin/$branch."
    note "Свои коммиты лежат в ветке $backup — вернуться к ним: git checkout $backup"
    return 0
  fi

  fail "ничего не трогаю. Твои коммиты на месте, посмотреть их:
  git log --oneline origin/$branch..HEAD"
}
