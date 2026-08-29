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

step "1/8 Проверяю, что нет несохранённых правок"
if [ -n "$(git status --porcelain)" ]; then
  git status --short
  fail "рабочее дерево грязное. Сначала закоммить или отбрось эти правки —
иначе git checkout не переключит ветку, а собрано будет непонятно что."
fi

step "2/8 Переключаюсь на $BRANCH и подтягиваю"
git fetch origin "$BRANCH"
git checkout "$BRANCH"
# --ff-only: если ветка разошлась с origin, лучше остановиться и разобраться,
# чем собрать молчаливый merge-результат.
git merge --ff-only "origin/$BRANCH" || fail "локальная $BRANCH разошлась с origin/$BRANCH.
Разберись с расхождением (см. .claude/skills/branch-flow/SKILL.md, сценарий Б)."

BUILD_ID="$(git rev-parse --short HEAD)"
echo "Ветка: $BRANCH"
echo "Коммит: $BUILD_ID  $(git log -1 --format=%s)"

step "3/8 Чищу прошлую сборку"
# Без этого Gradle способен отдать старый libapp.so, и APK окажется свежим
# по дате, но старым по содержимому.
flutter clean >/dev/null

step "4/8 Ставлю зависимости"
flutter pub get >/dev/null

APK="$REPO/build/app/outputs/flutter-apk/app-release.apk"
PKG="$(sed -n 's/.*applicationId = "\(.*\)".*/\1/p' android/app/build.gradle.kts | head -1)"
[ -n "$PKG" ] || fail "не нашёл applicationId в android/app/build.gradle.kts"
rm -f "$APK"

step "5/8 Собираю APK с меткой BUILD_ID=$BUILD_ID"
# --build-name кладёт коммит в versionName пакета. Это единственная метка,
# которую видно СНАРУЖИ приложения: по ней и adb, и «О приложении» в
# настройках телефона отвечают, что на самом деле установлено.
flutter build apk --release \
  --dart-define=BUILD_ID="$BUILD_ID" \
  --build-name="1.0.0-$BUILD_ID"

step "6/8 Проверяю, что APK действительно новый"
[ -f "$APK" ] || fail "APK не появился — сборка не прошла. Смотри вывод выше."

step "7/8 Проверяю, что внутрь APK попал именно этот коммит"
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

step "8/8 Ставлю на телефон и проверяю, что встало именно это"
# Самое слабое место всей цепочки — установка. Собранный APK легко остаётся
# лежать на диске: команду не запустили, телефон не подключён, установка
# отказала по несовпадению подписи. Снаружи это выглядит как «собрал, а
# изменений нет», и отличить это от настоящей поломки нельзя. Поэтому
# скрипт ставит сам и читает обратно версию с устройства.
COPY="$REPO/build/chrolingo-$BUILD_ID.apk"
cp "$APK" "$COPY"

if [ "${NO_ADB:-0}" = "1" ]; then
  echo "  NO_ADB=1 — установку не трогаю"
  MANUAL=1
elif ! command -v adb >/dev/null 2>&1; then
  echo "  adb не установлен — ставим файл вручную, это нормально"
  MANUAL=1
elif [ -z "$(adb devices | awk 'NR>1 && $2=="device"')" ]; then
  echo "  телефон по USB не подключён — ставим файл вручную, это нормально"
  MANUAL=1
else
  MANUAL=0
  echo "  ставлю..."
  if ! adb install -r "$APK"; then
    fail "установка не прошла. Чаще всего мешает прежняя подпись — тогда:
  adb uninstall $PKG && adb install \"$APK\""
  fi
  INSTALLED="$(adb shell dumpsys package "$PKG" 2>/dev/null \
    | sed -n 's/.*versionName=//p' | head -1 | tr -d '\r')"
  echo "  на телефоне сейчас: $INSTALLED"
  [ "$INSTALLED" = "1.0.0-$BUILD_ID" ] \
    || fail "на телефоне версия «$INSTALLED», а собрали «1.0.0-$BUILD_ID».
Установка не заменила приложение. Снеси и поставь заново:
  adb uninstall $PKG && adb install \"$APK\""
fi

cat <<EOF

────────────────────────────────────────────────
ГОТОВО.  Коммит в сборке: $BUILD_ID
APK: $APK
EOF
if [ "${MANUAL:-0}" = "1" ]; then
cat <<EOF

Скинь на телефон и установи ЭТОТ файл (имя с номером сборки, чтобы не
перепутать со старым):

  $COPY

Как убедиться, что встало именно оно — любой из двух способов:
  * в приложении: «Одиночная Игра», под заголовком … · $BUILD_ID
  * в телефоне: Настройки -> Приложения -> Chrolingo -> версия
                должна быть 1.0.0-$BUILD_ID
EOF
else
cat <<EOF

Приложение установлено и проверено: versionName=1.0.0-$BUILD_ID
────────────────────────────────────────────────
EOF
fi
