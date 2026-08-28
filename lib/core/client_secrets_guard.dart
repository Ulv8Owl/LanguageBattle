import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Единственные переменные, которым МОЖНО быть в клиентском `.env`.
///
/// `.env` объявлен ассетом в pubspec.yaml, то есть он целиком лежит внутри
/// собранного APK/IPA и извлекается из него за минуту любым желающим —
/// это не хранилище секретов, а конфигурация публичного клиента.
/// SUPABASE_ANON_KEY публичным быть и должен: он не даёт никаких прав сам
/// по себе, доступ к данным определяют RLS-политики.
const _allowedClientKeys = {'SUPABASE_URL', 'SUPABASE_ANON_KEY'};

/// Имена, по которым узнаём серверный секрет, случайно положенный в клиент.
const _forbiddenPatterns = [
  'LLM_',
  'ASR_',
  'SERVICE_ROLE',
  'SERVICE_KEY',
  'SECRET',
  'PRIVATE_KEY',
];

/// Проверка, что в клиентскую сборку не просочились серверные ключи.
///
/// Ключи LLM-судьи и распознавания речи живут ТОЛЬКО в секретах Edge
/// Function на стороне Supabase и никогда не покидают сервер: приложение
/// вызывает не провайдеров, а свою базу, а к провайдерам ходит уже Edge
/// Function. Если такой ключ однажды случайно допишут в `.env`, он молча
/// уедет в магазин приложений вместе со сборкой — эта проверка не даёт
/// такой сборке даже запуститься в отладке.
///
/// В релизе не роняем приложение у живых игроков (падение на старте хуже
/// самой утечки, а утечка к тому моменту уже произошла) — но громко пишем
/// в лог. Ловить это должна отладочная сборка и CI, до публикации.
void assertNoServerSecretsInClient() {
  final leaked = <String>[];
  for (final name in dotenv.env.keys) {
    if (_allowedClientKeys.contains(name)) continue;
    final upper = name.toUpperCase();
    if (_forbiddenPatterns.any(upper.contains)) leaked.add(name);
  }
  if (leaked.isEmpty) return;

  final message =
      'В клиентский .env попали серверные секреты: ${leaked.join(', ')}. '
      'Файл .env целиком попадает в собранное приложение — эти ключи '
      'должны храниться только в секретах Edge Function '
      '(npx supabase secrets set ...). Удалите их из .env и '
      'ОБЯЗАТЕЛЬНО перевыпустите: считайте скомпрометированными.';

  if (kReleaseMode) {
    debugPrint('SECURITY: $message');
    return;
  }
  throw StateError(message);
}
