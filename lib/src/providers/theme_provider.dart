import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

/// Theme state provider - simplified with color seed selection
class ThemeState extends ChangeNotifier {
  static const String _colorKey = 'color_seed';
  static const String _modeKey = 'theme_mode';

  ThemeMode _themeMode = ThemeMode.system;
  ColorSeed _colorSeed = ColorSeed.baseColor;

  ThemeMode get themeMode => _themeMode;
  ColorSeed get colorSeed => _colorSeed;
  bool get isDark => _themeMode == ThemeMode.dark;

  ThemeState() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_modeKey) ?? 0; // default system
    final colorIndex = prefs.getInt(_colorKey) ?? 0;
    _themeMode = ThemeMode.values[modeIndex.clamp(0, 2)];
    _colorSeed =
        ColorSeed.values[colorIndex.clamp(0, ColorSeed.values.length - 1)];
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_modeKey, _themeMode.index);
    await prefs.setInt(_colorKey, _colorSeed.index);
  }

  void toggleMode() {
    _themeMode = _themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    _save();
    notifyListeners();
  }

  void setColorSeed(ColorSeed seed) {
    _colorSeed = seed;
    _save();
    notifyListeners();
  }

  void nextColorSeed() {
    final next = (_colorSeed.index + 1) % ColorSeed.values.length;
    _colorSeed = ColorSeed.values[next];
    _save();
    notifyListeners();
  }
}
