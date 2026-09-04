import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Палитра Chrolingo — приложение держится в единой
/// чёрно-жёлтой палитре, что и макеты.
class AppColors {
  static const navy1 = Color(0xFF0D0D10);
  static const navy2 = Color(0xFF17171B);
  static const navy3 = Color(0xFF212126);
  static const navy4 = Color(0xFF2C2C31);
  static const line = Color(0x24FFFFFF);
  static const lineStrong = Color(0x42FFFFFF);
  static const gold = Color(0xFFFFD400);
  static const gold2 = Color(0xFFF5C400);
  static const goldSoft = Color(0x24FFD400);
  static const cyan = Color(0xFFF2F2F5);
  static const plat = Color(0xFF4FAE9C);
  static const diamond = Color(0xFF5C8AC7);
  static const master = Color(0xFF9C74C4);
  static const gm = Color(0xFFC65468);
  static const ember = Color(0xFFDB7A6A);
  static const cream = Color(0xFFF5F5F7);
  static const muted = Color(0xFF8A8A92);
  static const ok = Color(0xFF4FB876);
  static const danger = Color(0xFFE85870);
}

/// Шрифты макета: Bungee (лого), Baloo 2 (UI/кнопки/заголовки),
/// Manrope (обычный текст — используется как textTheme по умолчанию),
/// Space Mono (цифры/лейблы).
/// Шрифты приложения.
///
/// ГЛАВНОЕ ТРЕБОВАНИЕ К ЛЮБОМУ ШРИФТУ ЗДЕСЬ: он обязан содержать И ЛАТИНИЦУ,
/// И КИРИЛЛИЦУ. Иначе получается то, с чего этот класс переписан: Baloo 2
/// (ui) и Space Mono (mono) кириллицы не содержат вовсе, и Flutter молча
/// подставлял для русского текста системный шрифт. В итоге один и тот же
/// экран выглядел по-разному на русском и английском — английские надписи
/// рисовались фигурным Baloo 2, русские системным Roboto, — а внутри
/// русского интерфейса расходились даже соседние элементы: цифры рейтинга
/// шли моноширинным Space Mono, а подпись рядом с ними — системным.
///
/// Ни одной ошибки при этом не возникало: подстановка недостающего глифа —
/// штатное поведение, и заметить её можно только глазами. Поэтому проверять
/// новый шрифт надо ДО того, как он попал сюда: у семейства на fonts.google.
/// com в наборах (subsets) должен быть Cyrillic.
class AppFonts {
  /// Крупный акцентный шрифт для вывесок. Сейчас в приложении не
  /// используется ни разу; оставлен на будущее — но уже на семействе с
  /// кириллицей, чтобы не вернуть ту же проблему, когда он понадобится.
  static TextStyle brand({double fontSize = 32, Color color = AppColors.gold}) =>
      GoogleFonts.russoOne(fontSize: fontSize, color: color, letterSpacing: 0.2);

  /// Основной текст интерфейса. Manrope — то же семейство, что и в
  /// textTheme ниже: так надписи в виджетах и системный текст Material
  /// (диалоги, подсказки полей) выглядят одинаково.
  static TextStyle ui({
    double fontSize = 14,
    FontWeight weight = FontWeight.w700,
    Color color = AppColors.cream,
  }) =>
      GoogleFonts.manrope(fontSize: fontSize, fontWeight: weight, color: color);

  /// Моноширинный: рейтинг, счётчики, коды уровней. JetBrains Mono вместо
  /// Space Mono по единственной причине — в нём есть кириллица, а
  /// моноширинным здесь набираются и русские подписи («ОТЛАДКА», названия
  /// лиг), а не только цифры.
  static TextStyle mono({
    double fontSize = 11,
    FontWeight weight = FontWeight.w400,
    Color color = AppColors.muted,
  }) =>
      GoogleFonts.jetBrainsMono(fontSize: fontSize, fontWeight: weight, color: color);
}

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final manropeText = GoogleFonts.manropeTextTheme(base.textTheme).apply(
    bodyColor: AppColors.cream,
    displayColor: AppColors.cream,
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.navy1,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.gold,
      secondary: AppColors.gold,
      surface: AppColors.navy2,
      error: AppColors.danger,
    ),
    textTheme: manropeText,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.navy1,
      foregroundColor: AppColors.cream,
      elevation: 0,
      titleTextStyle: AppFonts.ui(fontSize: 16, weight: FontWeight.w800),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.gold,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: AppFonts.ui(fontSize: 14, weight: FontWeight.w800, color: Colors.black)
            .copyWith(letterSpacing: 0.6),
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
  );
}
