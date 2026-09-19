#!/usr/bin/env bash
#
# Серверная часть: миграции и Edge Functions. Обычно вызывается из
# ./tools/release.sh, но можно и отдельно: ./tools/deploy_server.sh [ветка]
#
# Порядок внутри важен: сначала база, потом функции. Функция, задеплоенная
# раньше своей миграции, будет писать в столбец, которого ещё нет.

set -euo pipefail
cd "$(dirname "$0")/.."
# Без аргумента — ТЕКУЩАЯ ветка, а не features. Зашитое имя означало, что
# запуск на любой другой ветке сверяется с чужим origin и отказывается
# работать, ничего толком не объяснив: «дерево не совпадает с origin/features»
# на ветке Exp3 — это загадка, а не сообщение.
BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
# shellcheck source=tools/lib.sh
source tools/lib.sh

step "0/2 Проверяю, что на диске лежит актуальный код"
require_clean_tree
require_synced "$BRANCH"
note "Деплою $(git rev-parse --short HEAD)  $(git log -1 --format=%s)"

step "1/2 Применяю миграции"
# ОБЕ МИГРАЦИИ ВЕТОК СРАВНЕНИЯ ЛЕЖАТ НА ВСЕХ ВЕТКАХ — так папка миграций
# везде одинаковая, и история в базе всегда с ней сходится. Иначе после
# сборки одной ветки push с другой упирался бы в расхождение: то местный
# файл с меньшим номером не применён, то в базе есть версия, которой в папке
# нет.
#
# --include-all остаётся страховкой на случай базы, которая уже попала в
# смешанное состояние: он применяет всё недостающее независимо от номера.
# Для наших миграций это безопасно — они только добавляют колонки, и все
# через `if not exists`.
npx supabase db push --include-all

step "2/2 Деплою Edge Functions"
# evaluate-recording — воркер оценки; config-check — диагностика ключей;
# synthesize-speech — озвучка разбора (Google Text-to-Speech).
npx supabase functions deploy evaluate-recording
npx supabase functions deploy config-check
# Вход по нику. Проверку JWT НЕ отключаем: у клиента, который её зовёт,
# сессии ещё нет, но анонимный ключ проекта есть всегда — именно он и
# проверяется.
npx supabase functions deploy login
npx supabase functions deploy synthesize-speech
# transcribe-track — разбор записи игрока на слова со временем и переводом
# («Аудирование»). Функции здесь перечислены ПОИМЁННО, и это ловушка: новая
# функция молча остаётся незадеплоенной, а приложение получает 404 там, где
# ждёт разбор. Добавили функцию — добавьте строку сюда; тест сторожит, что
# ни одна папка из supabase/functions не забыта.
npx supabase functions deploy transcribe-track
# asr-audio отдаёт запись провайдеру распознавания по ссылке, кончающейся на
# .wav. --no-verify-jwt здесь ОБЯЗАТЕЛЕН: запрос приходит от провайдера, у
# которого токена Supabase нет и быть не может. Без проверки JWT — не значит
# без проверки: функция требует своей подписи на конкретный файл и срок.
npx supabase functions deploy asr-audio --no-verify-jwt

note "Сервер обновлён до $(git rev-parse --short HEAD)."
