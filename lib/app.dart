import 'package:flutter/material.dart';

import 'core/app_locale.dart';
import 'core/router.dart';
import 'core/theme.dart';

class LanguageBattleApp extends StatelessWidget {
  const LanguageBattleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Смена языка интерфейса перерисовывает приложение целиком. Так экраны
    // могут читать AppLocale.strings прямо в build() и не протаскивать
    // локаль через конструкторы и параметры маршрутов.
    return ValueListenableBuilder<String>(
      valueListenable: AppLocale.code,
      builder: (context, languageCode, _) => MaterialApp.router(
        title: 'Chrolingo',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        locale: Locale(languageCode),
        routerConfig: appRouter,
      ),
    );
  }
}
