import 'package:flutter/material.dart';

const Color _seedColor = Color(0xFF00B8D4);

/// Colores de estado con contraste suficiente sobre superficies oscuras.
abstract final class StatusColors {
  static const Color success = Color(0xFF4ADE80);
  static const Color warning = Color(0xFFFBBF24);
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: Brightness.dark,
  );
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainer,
      shape: rounded,
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
