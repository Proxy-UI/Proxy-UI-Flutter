import 'package:flutter/material.dart';

/// Responsive breakpoints
const double narrowScreenWidthThreshold = 450;
const double smallWidthBreakpoint = 500;
const double mediumWidthBreakpoint = 1000;
const double largeWidthBreakpoint = 1500;

/// Animation
const double transitionLength = 500;

/// Layout status for responsive design
enum LayoutStatus { moreSmall, small, medium, large }

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

/// Color seed options
enum ColorSeed {
  aurora('Aurora', Color(0xFF22D3EE)),
  indigo('Indigo', Colors.indigo),
  blue('Blue', Colors.blue),
  teal('Teal', Colors.teal),
  green('Green', Colors.green),
  yellow('Yellow', Colors.yellow),
  orange('Orange', Colors.orange),
  deepOrange('Deep Orange', Colors.deepOrange),
  pink('Pink', Colors.pink);

  const ColorSeed(this.label, this.color);
  final String label;
  final Color color;
}

/// Log level utilities
class LogLevel {
  static const int trace = 0;
  static const int debug = 1;
  static const int info = 2;
  static const int warn = 3;
  static const int error = 4;

  static const List<String> names = ['TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR'];

  static int normalize(int level) {
    if (level < trace) {
      return trace;
    }
    if (level > error) {
      return error;
    }
    return level;
  }

  // Threshold-based filtering: INFO means INFO/WARN/ERROR.
  static bool includes({required int threshold, required int entryLevel}) {
    return normalize(entryLevel) >= normalize(threshold);
  }

  static Color getColor(int level, {bool isDark = true}) {
    switch (level) {
      case 0:
        return isDark ? const Color(0xFF78909C) : const Color(0xFF607D8B);
      case 1:
        return isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2);
      case 2:
        return isDark ? const Color(0xFF81C784) : const Color(0xFF388E3C);
      case 3:
        return isDark ? const Color(0xFFFFD54F) : const Color(0xFFF57C00);
      case 4:
        return isDark ? const Color(0xFFE57373) : const Color(0xFFD32F2F);
      default:
        return isDark ? const Color(0xFF9AA0A6) : const Color(0xFF757575);
    }
  }

  static String getName(int level) {
    final normalized = normalize(level);
    if (normalized >= 0 && normalized < names.length) {
      return names[normalized];
    }
    return 'UNKNOWN';
  }

  static String getThresholdLabel(int level) {
    final normalized = normalize(level);
    final base = getName(normalized);
    if (normalized == error) {
      return base;
    }
    return '$base+';
  }
}
