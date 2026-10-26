// lib/theme.dart
import 'package:flutter/material.dart';

class AppColors {
  static const bg = Color(0xFF0D1117);
  static const surface = Color(0xFF161B22);
  static const surfaceHigh = Color(0xFF1F2630);
  static const outline = Color(0xFF2A313C);
  static const accent = Color(0xFF4C8DFF);
  static const muted = Color(0xFF8B949E);
  static const danger = Color(0xFFF85149);
  static const success = Color(0xFF3FB950);
  static const warning = Color(0xFFD29922);

  static const myBubble = Color(0xFF2F6FEB);
  static const otherBubble = Color(0xFF262D37);

  static const avatarPalette = [
    Color(0xFF4C8DFF), Color(0xFFF85149), Color(0xFF3FB950), Color(0xFFA371F7), //
    Color(0xFFD29922), Color(0xFF39C5CF), Color(0xFFDB61A2), Color(0xFF6E7BFF),
  ];
  static const bubblePalette = [
    Color(0xFF2F6FEB), Color(0xFF238636), Color(0xFF8957E5), Color(0xFFBD561D), //
    Color(0xFFDA3633), Color(0xFF1B7C83), Color(0xFFBF4B8A), Color(0xFF4C5BD4),
    Color(0xFF262D37), Color(0xFF30363D), Color(0xFF3B4250), Color(0xFF1F6FEB),
  ];
}

const kFast = Duration(milliseconds: 160);
const kMedium = Duration(milliseconds: 260);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.accent, brightness: Brightness.dark).copyWith(
    primary: AppColors.accent,
    onPrimary: Colors.white,
    surface: AppColors.surface,
    surfaceContainerLowest: AppColors.bg,
    surfaceContainerLow: AppColors.surface,
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: AppColors.surfaceHigh,
    outline: AppColors.outline,
    outlineVariant: AppColors.outline,
    error: AppColors.danger,
  );
  final radius = BorderRadius.circular(14);
  const transitions = SmoothPageTransitionsBuilder();

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    splashFactory: InkRipple.splashFactory,
    visualDensity: VisualDensity.standard,
    dividerTheme: const DividerThemeData(color: AppColors.outline, thickness: 1, space: 1),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: const TextStyle(color: AppColors.muted),
      labelStyle: const TextStyle(color: AppColors.muted),
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: const BorderSide(color: AppColors.accent)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        side: const BorderSide(color: AppColors.outline),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: radius)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    listTileTheme: const ListTileThemeData(iconColor: AppColors.muted),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: transitions,
      TargetPlatform.windows: transitions,
      TargetPlatform.linux: transitions,
      TargetPlatform.macOS: transitions,
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}

/// Короткий переход между экранами: проявление + лёгкий сдвиг.
/// Только transform/opacity — дёшево для GPU на любой частоте кадров.
class SmoothPageTransitionsBuilder extends PageTransitionsBuilder {
  const SmoothPageTransitionsBuilder();

  static final _slide = Tween(begin: const Offset(0.05, 0), end: Offset.zero);

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(position: _slide.animate(curved), child: child),
    );
  }
}
