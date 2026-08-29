#!/usr/bin/env bash
#
# Сборка APK одной командой: ./tools/build.sh [ветка]
#
# Существует потому, что три раза подряд «функция не работает» означало «в
# телефоне не тот APK». Ручная последовательность из пяти команд молча
# переживает любую осечку: `git checkout` упал — собирается прежняя ветка;
# `flutter build` упал — на диске остаётся старый app-release.apk, и его же
# ставят на телефон. Скрипт на каждой такой осечке останавливается и говорит,
# что именно пошло не так.
#
# Собранный APK помечается коммитом: --dart-define=BUILD_ID=<sha> виден в
# шапке экрана Одиночной Игры. Забыть обновить метку нельзя — она берётся
# из git, а не пишется руками.

set -euo pipefail

BRANCH="${1:-features}"
cd "$(dirname "$0")/.."
REPO="$(pwd)"

step() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mОСТАНОВ: %s\033[0m\n' "$1" >&2; exit 1; }

step "1/7 Проверяю, что нет несохранённых правок"
if [ -n "$(git status --porcelain)" ]; then
  git status --short
  fail "рабочее дерево грязное. Сначала закоммить или отбрось эти правки —
иначе git checkout не переключит ветку, а собрано будет непонятно что."
fi

step "2/7 Переключаюсь на $BRANCH и подтягиваю"
git fetch origin "$BRANCH"
git checkout "$BRANCH"
# --ff-only: если ветка разошлась с origin, лучше остановиться и разобраться,
# чем собрать молчаливый merge-результат.
git merge --ff-only "origin/$BRANCH" || fail "локальная $BRANCH разошлась с origin/$BRANCH.
Разберись с расхождением (см. .claude/skills/branch-flow/SKILL.md, сценарий Б)."

BUILD_ID="$(git rev-parse --short HEAD)"
echo "Ветка: $BRANCH"
echo "Коммит: $BUILD_ID  $(git log -1 --format=%s)"

step "3/7 Чищу прошлую сборку"
# Без этого Gradle способен отдать старый libapp.so, и APK окажется свежим
# по дате, но старым по содержимому.
flutter clean >/dev/null

step "4/7 Ставлю зависимости"
flutter pub get >/dev/null

APK="$REPO/build/app/outputs/flutter-apk/app-release.apk"
rm -f "$APK"

step "5/7 Собираю APK с меткой BUILD_ID=$BUILD_ID"
flutter build apk --release --dart-define=BUILD_ID="$BUILD_ID"

step "6/7 Проверяю, что APK действительно новый"
[ -f "$APK" ] || fail "APK не появился — сборка не прошла. Смотри вывод выше."

step "7/7 Проверяю, что внутрь APK попал именно этот коммит"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SO="$(unzip -Z1 "$APK" 'lib/*/libapp.so' 2>/dev/null | head -1 || true)"
if [ -z "$SO" ]; then
  echo "  (libapp.so в APK не найден — пропускаю проверку метки)"
else
  unzip -p "$APK" "$SO" > "$TMP/libapp.so" 2>/dev/null \
    || fail "не смог распаковать $SO из APK — проверить метку нечем."
  # Метку ищем двумя способами. Dart складывает строки в AOT-снимок
  # однобайтовыми, только пока в них нет ничего, кроме латиницы; стоит метке
  # попасть в один литерал с кириллицей — компилятор сворачивает всё в UTF-16,
  # и `a33c377` лежит в файле как `a\0 3\0 3\0 …`. Первый вариант проверки
  # именно на этом и споткнулся, забраковав совершенно исправную сборку.
  if grep -aq "$BUILD_ID" "$TMP/libapp.so"; then
    echo "  метка $BUILD_ID найдена внутри APK"
  elif tr -d '\0' < "$TMP/libapp.so" | grep -aq "$BUILD_ID"; then
    echo "  метка $BUILD_ID найдена внутри APK (UTF-16)"
  else
    fail "внутри APK нет метки $BUILD_ID — это НЕ та сборка. Не ставь её на телефон."
  fi
fi

cat <<EOF

────────────────────────────────────────────────
ГОТОВО.  Коммит в сборке: $BUILD_ID
APK: $APK

Поставить на телефон:
  adb install -r "$APK"

Или скинуть файл вручную. В приложении открой «Одиночная Игра» — под
заголовком должно быть написано: … · $BUILD_ID
Если там другой номер — на телефоне осталась прежняя сборка.
────────────────────────────────────────────────
EOF
