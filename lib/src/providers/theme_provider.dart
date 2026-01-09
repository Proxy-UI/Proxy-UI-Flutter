import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Available color themes
enum AppTheme {
  cyberpunk, // Cyan + Green (default)
  sunset, // Orange + Pink
  ocean, // Blue + Teal
  forest, // Green + Brown
}

/// Theme state provider
class ThemeState extends ChangeNotifier {
  static const String _themeKey = 'app_theme';
  static const String _modeKey = 'theme_mode';

  ThemeMode _themeMode = ThemeMode.dark;
  AppTheme _appTheme = AppTheme.cyberpunk;

  ThemeMode get themeMode => _themeMode;
  AppTheme get appTheme => _appTheme;
  bool get isDark => _themeMode == ThemeMode.dark;

  ThemeState() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_modeKey) ?? 2; // default dark
    final themeIndex = prefs.getInt(_themeKey) ?? 0;
    _themeMode = ThemeMode.values[modeIndex.clamp(0, 2)];
    _appTheme =
        AppTheme.values[themeIndex.clamp(0, AppTheme.values.length - 1)];
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_modeKey, _themeMode.index);
    await prefs.setInt(_themeKey, _appTheme.index);
  }

  void toggleMode() {
    _themeMode = _themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    _save();
    notifyListeners();
  }

  void setTheme(AppTheme theme) {
    _appTheme = theme;
    _save();
    notifyListeners();
  }

  void nextTheme() {
    final next = (_appTheme.index + 1) % AppTheme.values.length;
    _appTheme = AppTheme.values[next];
    _save();
    notifyListeners();
  }
}

/// Theme color definitions
class ThemeColors {
  final Color primary;
  final Color primaryDark;
  final Color accent;
  final Color accentDark;
  final String name;
  final IconData icon;

  const ThemeColors({
    required this.primary,
    required this.primaryDark,
    required this.accent,
    required this.accentDark,
    required this.name,
    required this.icon,
  });

  static ThemeColors get(AppTheme theme) {
    switch (theme) {
      case AppTheme.cyberpunk:
        return const ThemeColors(
          primary: Color(0xFF00ACC1), // Softer cyan
          primaryDark: Color(0xFF00838F),
          accent: Color(0xFF26A69A), // Softer teal-green
          accentDark: Color(0xFF00897B),
          name: 'Cyberpunk',
          icon: Icons.bolt,
        );
      case AppTheme.sunset:
        return const ThemeColors(
          primary: Color(0xFFE64A19), // Deeper orange
          primaryDark: Color(0xFFBF360C),
          accent: Color(0xFFD81B60), // Deeper pink
          accentDark: Color(0xFFAD1457),
          name: 'Sunset',
          icon: Icons.wb_twilight,
        );
      case AppTheme.ocean:
        return const ThemeColors(
          primary: Color(0xFF1976D2), // Deeper blue
          primaryDark: Color(0xFF0D47A1),
          accent: Color(0xFF0097A7), // Deeper cyan
          accentDark: Color(0xFF006064),
          name: 'Ocean',
          icon: Icons.water,
        );
      case AppTheme.forest:
        return const ThemeColors(
          primary: Color(0xFF388E3C), // Deeper green
          primaryDark: Color(0xFF1B5E20),
          accent: Color(0xFF6D4C41), // Deeper brown
          accentDark: Color(0xFF4E342E),
          name: 'Forest',
          icon: Icons.forest,
        );
    }
  }
}
