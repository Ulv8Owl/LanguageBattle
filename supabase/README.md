# Применение схемы БД

Эта облачная сессия Claude Code не может достучаться до Postgres/`*.supabase.co`
(сетевая политика окружения пропускает только HTTPS до ограниченного списка
dev-доменов), поэтому миграции нужно применить вручную — один раз, это займёт
пару минут.

## Как применить

1. Откройте ваш проект в [Supabase Dashboard](https://supabase.com/dashboard/project/gdturijctufmcctuztyn).
2. Перейдите в **SQL Editor** → **New query**.
3. Скопируйте содержимое `supabase/migrations/0001_initial_schema.sql`,
   вставьте и нажмите **Run**.
4. Новым запросом — то же самое с `supabase/migrations/0002_rls_and_storage.sql`.
5. Проверка: **Table Editor** должен показать все таблицы из раздела 4 спеки
   (`users`, `user_languages`, `matches`, `rounds`, `voice_recordings`,
   `grammar_errors`, `round_scores`, `evaluation_jobs`, `training_sessions`,
   `training_rounds`, `matchmaking_tickets`, `currency_wallets`,
   `cosmetic_items`, `user_inventory`, `battle_pass_seasons`,
   `battle_pass_progress`, `friendships`, `reports`), а в **Storage** —
   приватный бакет `voice-recordings`.

## Auth

Email/password включён в Supabase по умолчанию — ничего дополнительно
настраивать не нужно. Если в **Authentication → Providers → Email** включено
подтверждение почты ("Confirm email"), тестовым аккаунтам нужно будет
подтвердить письмо, прежде чем логиниться в приложении — для быстрого
локального теста можно временно отключить это в настройках проекта.

## Ручная постановка тестового матча (Шаг 3, Wizard-of-Oz)

Матч не создаётся через матчмейкинг — вы вставляете строку в `matches`
напрямую через **Table Editor** (или SQL Editor):

```sql
insert into matches (player_a_id, player_b_id, game_mode, language_pair, status)
values (
  '<uuid тестового пользователя A>',
  '<uuid тестового пользователя B>',
  'sparring',   -- или 'native_duel'
  'en',         -- для sparring: код общего изучаемого языка
  'in_progress'
);
```

Для `native_duel` `language_pair` — это `"<родной A>-<родной B>"`, например
`es-en`: игрок A — носитель испанского (учит английский), игрок B — носитель
английского (учит испанский). Приложение полагается именно на этот порядок
при выборе языка для слотов `native`/`target` каждого игрока — не перепутайте
местами `player_a_id`/`player_b_id` относительно `language_pair`.

Оба тестовых аккаунта, зайдя в приложение, увидят этот матч на экране
"Арена" и смогут открыть один и тот же бой.

## Простановка баллов за раунд

После того как оба голосовых в раунде загружены (видно в `voice_recordings`
и приложение показывает их в ленте боя), откройте `round_scores` в Table
Editor и вставьте по одной строке на каждого игрока для этого `round_id`:

```sql
insert into round_scores (round_id, user_id, score, ai_feedback)
values ('<round_id>', '<user_id>', 8, 'Неплохо, есть небольшая ошибка в порядке слов.');
```

Как только обе строки появятся — приложение (через Realtime) само покажет
баллы в ленте и создаст следующий раунд. После 10-го раунда матч сам
завершится и обе стороны увидят экран итогов.
