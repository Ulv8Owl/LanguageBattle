import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/app_locale.dart';
import 'core/client_secrets_guard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  // .env целиком уезжает внутрь APK/IPA, поэтому ключи провайдеров (LLM,
  // распознавание речи) там не должны появляться никогда — они живут в
  // секретах Edge Function на стороне Supabase.
  assertNoServerSecretsInClient();

  await Supabase.initialize(
    url: dotenv.get('SUPABASE_URL'),
    publishableKey: dotenv.get('SUPABASE_ANON_KEY'),
  );

  // Язык интерфейса поднимается ДО первого кадра: иначе приложение
  // покажет русский экран и через полсекунды перерисует его на английский.
  // Supabase уже поднят выше, поэтому серверное значение тоже доступно.
  await AppLocale.load();

  runApp(const LanguageBattleApp());
}
