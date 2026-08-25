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
5. Новым запросом — `supabase/migrations/0003_grants.sql` (без этого шага
   вход в приложение падает с `permission denied for table ...`, см. ниже).
6. Новым запросом — `supabase/migrations/0004_ai_pipeline_trigger.sql`
   (триггер, дёргающий Edge Function на новый `evaluation_jobs` — см. раздел
   "Подключение реального ИИ-пайплайна" ниже, без секретов триггер просто
   молчит, ничего не ломает).
7. Новым запросом — `supabase/migrations/0005_progression_and_shop.sql`
   (XP/валюта/ELO при завершении матча, каталог магазина).
8. Проверка: **Table Editor** должен показать все таблицы из раздела 4 спеки
   (`users`, `user_languages`, `matches`, `rounds`, `voice_recordings`,
   `grammar_errors`, `round_scores`, `evaluation_jobs`, `training_sessions`,
   `training_rounds`, `matchmaking_tickets`, `currency_wallets`,
   `cosmetic_items`, `user_inventory`, `battle_pass_seasons`,
   `battle_pass_progress`, `friendships`, `reports`), а в **Storage** —
   приватный бакет `voice-recordings`.

### Если 0001 падает с "relation ... already exists"

Значит предыдущий прогон выполнился частично (упал на середине списка
`create table`), и часть таблиц уже создана. Прогоните
`supabase/migrations/0000_reset.sql` (полностью сносит всё, что могли
успеть создать 0001/0002 — безопасно, пока в базе ещё нет реальных данных),
затем заново 0001, 0002 и 0003 по порядку.

### Если при входе в приложение "permission denied for table ..."

RLS-политики (0002) работают только поверх базового табличного GRANT —
без него Postgres блокирует запрос ещё до применения политик. На новых
Supabase-проектах это обычно настроено автоматически, но если по какой-то
причине не подхватилось — прогоните `supabase/migrations/0003_grants.sql`
(безопасно повторно, ошибок не даёт).

## Auth

Email/password включён в Supabase по умолчанию — ничего дополнительно
настраивать не нужно.

**Обязательно отключите подтверждение почты для этой тестовой фазы**:
**Authentication → Sign In / Providers → Email** → выключите **"Confirm
email"**. Причина: письмо подтверждения по умолчанию ссылается на
`http://localhost:3000` (Site URL для веб-разработки) — в мобильном
приложении без своего веб-сайта эта ссылка никуда не ведёт ("Unable to
connect"). Правильная настройка deep link для подтверждения по почте в
мобильном приложении — отдельная задача не для этой фазы; сейчас проще и
быстрее просто выключить обязательное подтверждение: `signUp()` тогда сразу
возвращает сессию, и экран онбординга открывается без единого клика по
почте.

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

## Оценка раундов — теперь настоящая (Фаза 2)

Баллы больше не проставляются вручную. Как только оба игрока записали
голосовое, клиент сам:

1. Распознаёт речь **on-device** (встроенный движок Android/iOS через
   пакет `speech_to_text`) и кладёт транскрипт в `voice_recordings.transcript`
   сразу при загрузке — без отдельного облачного ASR-шага (раздел 9.1,
   временное упрощение до перехода на полноценный ASR-адаптер).
2. Создаёт `evaluation_jobs` (status='pending').
3. Триггер на этой таблице (см. ниже) дёргает Edge Function
   `evaluate-recording`, которая вызывает LLM-судью (DeepSeek), считает
   балл по формуле раздела 9.5 и пишет `round_scores`/`grammar_errors`.
4. Приложение видит новый счёт через Realtime и само создаёт следующий
   раунд; после 10-го — вызывает `finalize_match` (пересчёт ELO, валюта,
   опыт) и показывает экран итогов.

Если что-то в пайплайне не настроено (см. ниже), баллы просто не появятся —
раунд зависнет в ожидании. В этом случае можно по-прежнему вставить
`round_scores` вручную как временный обход, пока чините пайплайн.

## Подключение реального ИИ-пайплайна (DeepSeek)

Нужны Supabase CLI и логин (`npx supabase login`, один раз).

1. **Задеплойте Edge Function**:
   ```
   npx supabase link --project-ref gdturijctufmcctuztyn
   npx supabase functions deploy evaluate-recording
   ```
2. **Секреты самой функции** (не попадают в git, хранятся в Supabase):
   ```
   npx supabase secrets set LLM_API_KEY=<ваш DeepSeek API key>
   npx supabase secrets set LLM_BASE_URL=https://api.deepseek.com/v1
   npx supabase secrets set LLM_MODEL=deepseek-chat
   ```
   (`LLM_BASE_URL`/`LLM_MODEL` можно не задавать — это и есть значения по
   умолчанию; меняете их, когда захотите перейти на другого провайдера
   из раздела 9.2, без единой правки кода.)
3. **Секреты для триггера БД** (URL функции + service_role key — их
   отдельно кладём в Supabase Vault через SQL Editor, чтобы они не попали
   в этот репозиторий):
   ```sql
   select vault.create_secret(
     'https://gdturijctufmcctuztyn.supabase.co/functions/v1/evaluate-recording',
     'evaluate_recording_url'
   );
   select vault.create_secret(
     '<ваш service_role key>',
     'service_role_key'
   );
   ```
   Если раньше уже создавали такие секреты и надо заменить значение —
   используйте `select vault.update_secret(id, new_secret) ...` (id
   секрета видно в `select * from vault.secrets;`), а не повторный
   `create_secret` (он создаст дубликат с тем же именем).
4. Проверка: запишите тестовый раунд как обычно (реальный бой или вручную
   вставленный `voice_recordings` + `evaluation_jobs`) и посмотрите
   **Edge Functions → evaluate-recording → Logs** в Dashboard — там будет
   видно, дошёл ли вызов и что ответил DeepSeek.

Пока эти секреты не заданы, триггер просто пишет `WARNING` в логи Postgres
и ничего не делает — старый Wizard-of-Oz путь (баллы руками через Table
Editor) продолжает работать как временный запасной вариант.
