import 'package:flutter/material.dart';

/// Responsive breakpoints
const double smallWidthBreakpoint = 500;
const double mediumWidthBreakpoint = 1000;
const double largeWidthBreakpoint = 1500;

/// Spacing constants
const double tinySpacing = 4.0;
const double smallSpacing = 8.0;
const double mediumSpacing = 16.0;
const double largeSpacing = 24.0;
const double extraLargeSpacing = 32.0;

/// Animation durations
const Duration shortDuration = Duration(milliseconds: 200);
const Duration mediumDuration = Duration(milliseconds: 400);
const Duration longDuration = Duration(milliseconds: 600);

/// Navigation animation curve
const Curve navCurve = Curves.easeInOutCubicEmphasized;

/// App color scheme - Cyberpunk/Aviation theme
class AppColors {
  // Primary palette - Neon cyan
  static const Color primaryCyan = Color(0xFF00E5FF);
  static const Color primaryCyanDark = Color(0xFF00B8D4);

  // Accent - Electric green
  static const Color accentGreen = Color(0xFF00FF88);
  static const Color accentGreenDark = Color(0xFF00C853);

  // Warning/Error
  static const Color warningAmber = Color(0xFFFFAB00);
  static const Color errorRed = Color(0xFFFF1744);

  // Background gradients
  static const Color bgDark = Color(0xFF0A0E14);
  static const Color bgMedium = Color(0xFF121820);
  static const Color bgLight = Color(0xFF1A2332);

  // Surface colors
  static const Color surfaceDark = Color(0xFF151C28);
  static const Color surfaceLight = Color(0xFF1E2736);

  // Text colors
  static const Color textPrimary = Color(0xFFE8EAED);
  static const Color textSecondary = Color(0xFF9AA0A6);
  static const Color textMuted = Color(0xFF5F6368);

  // Log level colors
  static const Color logTrace = Color(0xFF78909C);
  static const Color logDebug = Color(0xFF64B5F6);
  static const Color logInfo = Color(0xFF81C784);
  static const Color logWarn = Color(0xFFFFD54F);
  static const Color logError = Color(0xFFE57373);
}

/// Log level utilities
class LogLevel {
  static const List<String> names = ['TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR'];

  static Color getColor(int level) {
    switch (level) {
      case 0:
        return AppColors.logTrace;
      case 1:
        return AppColors.logDebug;
      case 2:
        return AppColors.logInfo;
      case 3:
        return AppColors.logWarn;
      case 4:
        return AppColors.logError;
      default:
        return AppColors.textMuted;
    }
  }

  static String getName(int level) {
    if (level >= 0 && level < names.length) {
      return names[level];
    }
    return 'UNKNOWN';
  }
}
