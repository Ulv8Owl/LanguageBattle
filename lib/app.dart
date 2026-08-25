import 'package:flutter/material.dart';

import 'core/router.dart';
import 'core/theme.dart';

class LanguageBattleApp extends StatelessWidget {
  const LanguageBattleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Chrolingo',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: appRouter,
    );
  }
}
