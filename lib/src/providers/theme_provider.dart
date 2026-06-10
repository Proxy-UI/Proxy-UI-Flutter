import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

/// Theme state provider - simplified with color seed selection
class ThemeState extends ChangeNotifier {
  static const String _colorKey = 'color_seed';
  static const String _modeKey = 'theme_mode';

  ThemeMode _themeMode = ThemeMode.system;
  ColorSeed _colorSeed = ColorSeed.aurora;
  bool _isDisposed = false;

  ThemeMode get themeMode => _themeMode;
  ColorSeed get colorSeed => _colorSeed;
  bool get isDark => _themeMode == ThemeMode.dark;

  ThemeState() {
    _load();
  }

  void _safeNotifyListeners() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeIndex = prefs.getInt(_modeKey) ?? 0; // default system
      final colorIndex = prefs.getInt(_colorKey) ?? 0;
      _themeMode = ThemeMode.values[modeIndex.clamp(0, 2)];
      _colorSeed =
          ColorSeed.values[colorIndex.clamp(0, ColorSeed.values.length - 1)];
      _safeNotifyListeners();
    } catch (error, stackTrace) {
      debugPrint('Failed to load theme settings: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_modeKey, _themeMode.index);
      await prefs.setInt(_colorKey, _colorSeed.index);
    } catch (error, stackTrace) {
      debugPrint('Failed to persist theme settings: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void toggleMode() {
    _themeMode = _themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    unawaited(_save());
    _safeNotifyListeners();
  }

  void setColorSeed(ColorSeed seed) {
    _colorSeed = seed;
    unawaited(_save());
    _safeNotifyListeners();
  }

  void nextColorSeed() {
    final next = (_colorSeed.index + 1) % ColorSeed.values.length;
    _colorSeed = ColorSeed.values[next];
    unawaited(_save());
    _safeNotifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
