#!/usr/bin/env bash
#
# ПРОВЕРКА НАТИВНОЙ ЧАСТИ БЕЗ ANDROID SDK.
#
# Долгое время про Kotlin в этом проекте было сказано «проверить нечем»:
# Android SDK в облачной сессии не ставится, dl.google.com закрыт
# сетевой политикой. Это оказалось неправдой. Нужны ровно две вещи, и обе
# лежат там, куда доступ есть:
#
#   * компилятор Kotlin — релизы JetBrains на GitHub;
#   * классы самого Android — org.robolectric:android-all с Maven
#     Central. Это НАСТОЯЩИЙ framework нужного уровня API, а не заглушки:
#     подписи методов там те же, что на телефоне.
#
# Поэтому опечатка в имени метода, неверный тип, забытая скобка —
# ловятся здесь, а не «сборкой у владельца через двадцать минут».
#
# ЧЕГО ЭТА ПРОВЕРКА НЕ ДЕЛАЕТ, и путать это нельзя: она не собирает APK.
# Ресурсы, манифест, Gradle, плагины, R8 — всё это мимо. «Скомпилировался
# Kotlin» и «собирается приложение» — разные утверждения.
#
# Запуск: ./tools/check_native.sh
# Скачанное кладётся в кеш и второй раз не качается (около 280 МБ).

set -euo pipefail
cd "$(dirname "$0")/.."

KOTLIN_VERSION="2.0.21"
# Уровень API берём тот же, под который собираемся (compileSdk 36 = 16).
ANDROID_ALL="16-robolectric-13921718"
CACHE="${CHROLINGO_NATIVE_CACHE:-$HOME/.cache/chrolingo-native}"
SRC="android/app/src/main/kotlin/com/chrolingo/app"

mkdir -p "$CACHE"

if [ ! -x "$CACHE/kotlinc/bin/kotlinc" ]; then
  echo "Качаю компилятор Kotlin $KOTLIN_VERSION…"
  curl -sSL -o "$CACHE/kotlinc.zip" \
    "https://github.com/JetBrains/kotlin/releases/download/v$KOTLIN_VERSION/kotlin-compiler-$KOTLIN_VERSION.zip"
  unzip -q -o "$CACHE/kotlinc.zip" -d "$CACHE"
  rm -f "$CACHE/kotlinc.zip"
fi

if [ ! -f "$CACHE/android-all.jar" ]; then
  echo "Качаю классы Android ($ANDROID_ALL)…"
  curl -sSL -o "$CACHE/android-all.jar" \
    "https://repo1.maven.org/maven2/org/robolectric/android-all/$ANDROID_ALL/android-all-$ANDROID_ALL.jar"
fi

CP="$CACHE/android-all.jar"

# Мост к Flutter проверяется только если под рукой есть движок. Путь к
# самому Flutter берём из android/local.properties — там он записан
# точно, а PATH в чужой оболочке может его и не содержать (на этом
# проверка один раз молча пропустила половину файлов).
FLUTTER_ROOT=""
if [ -f android/local.properties ]; then
  FLUTTER_ROOT="$(sed -n 's/^flutter\.sdk=//p' android/local.properties | head -1)"
fi
if [ -z "$FLUTTER_ROOT" ] && command -v flutter >/dev/null 2>&1; then
  FLUTTER_ROOT="$(cd "$(dirname "$(readlink -f "$(command -v flutter)")")/.." && pwd)"
fi

ENGINE_JAR=""
if [ -n "$FLUTTER_ROOT" ] && \
   [ -f "$FLUTTER_ROOT/bin/cache/artifacts/engine/android-arm64/flutter.jar" ]; then
  ENGINE_JAR="$FLUTTER_ROOT/bin/cache/artifacts/engine/android-arm64/flutter.jar"
  CP="$CP:$ENGINE_JAR"
fi

# MainActivity намеренно в стороне: он наследуется от FlutterActivity, а
# тот тянет androidx.lifecycle, которого без Gradle взять неоткуда.
FILES=()
for f in "$SRC"/*.kt; do
  case "$f" in
    */MainActivity.kt) continue ;;
    */RichNotifications.kt)
      # Мост к Dart без движка не проверить. МОЛЧА ПРОПУСКАТЬ НЕЛЬЗЯ:
      # «проверка прошла» при половине проверенных файлов — это не
      # проверка, а её вид.
      if [ -z "$ENGINE_JAR" ]; then
        echo "ВНИМАНИЕ: движка Flutter нет в кеше, $f НЕ проверяется."
        echo "          Сделайте flutter precache --android и повторите."
        continue
      fi
      ;;
  esac
  FILES+=("$f")
done

echo "Компилирую: ${FILES[*]}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"$CACHE/kotlinc/bin/kotlinc" -cp "$CP" -d "$OUT" "${FILES[@]}"

# Разметка уведомления и подложки: сломанный XML собирается в APK ровно
# до момента показа, а потом даёт «не удалось показать уведомление».
python3 - <<'PY'
import glob
import sys
import xml.etree.ElementTree as ET

bad = []
for path in (glob.glob('android/app/src/main/res/layout/*.xml')
             + glob.glob('android/app/src/main/res/drawable/*.xml')
             + glob.glob('android/app/src/main/res/raw/*.xml')
             + ['android/app/src/main/AndroidManifest.xml']):
    try:
        ET.parse(path)
    except ET.ParseError as e:
        bad.append('%s: %s' % (path, e))

if bad:
    print('\n'.join(bad))
    sys.exit(1)
print('XML в порядке')
PY

echo "Нативная часть компилируется. Это НЕ значит, что собирается APK."
