import 'package:flutter/material.dart';

/// Colors lifted from the lexarena mockups so the placeholder screens don't
/// look like default Material out of the box.
class AppColors {
  static const navy1 = Color(0xFF0D0D10);
  static const navy2 = Color(0xFF17171B);
  static const navy3 = Color(0xFF212126);
  static const gold = Color(0xFFFFD400);
  static const cream = Color(0xFFF5F5F7);
  static const muted = Color(0xFF8A8A92);
  static const ok = Color(0xFF4FB876);
  static const danger = Color(0xFFE85870);
}

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.navy1,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.gold,
      secondary: AppColors.gold,
      surface: AppColors.navy2,
      error: AppColors.danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.navy1,
      foregroundColor: AppColors.cream,
      elevation: 0,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.gold,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.navy3,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.navy2,
      selectedItemColor: AppColors.gold,
      unselectedItemColor: AppColors.muted,
      showSelectedLabels: false,
      showUnselectedLabels: false,
      type: BottomNavigationBarType.fixed,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.cream,
      displayColor: AppColors.cream,
    ),
  );
}
