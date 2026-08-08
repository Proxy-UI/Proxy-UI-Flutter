import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Desktop behaviour that is not part of the proxy configuration.
///
/// `launchAtStartup` is owned by Windows rather than by this store: the user can
/// equally remove the entry from Task Manager's startup tab, so the registry is
/// read back instead of trusting a cached copy.
class DesktopSettings extends ChangeNotifier {
  DesktopSettings();

  static const MethodChannel _startupChannel = MethodChannel(
    'proxy_ui/startup',
  );
  static const String _minimizeToTrayKey = 'desktop_minimize_to_tray';

  static bool get isSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Only the Windows runner implements the sign-in entry today.
  static bool get supportsLaunchAtStartup => Platform.isWindows;

  bool _minimizeToTray = true;
  bool _launchAtStartup = false;
  bool _isLoaded = false;

  /// Hide to the tray on minimize instead of leaving a taskbar button behind.
  bool get minimizeToTray => _minimizeToTray;
  bool get launchAtStartup => _launchAtStartup;
  bool get isLoaded => _isLoaded;

  Future<void> load() async {
    if (!isSupported) {
      _isLoaded = true;
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      _minimizeToTray = prefs.getBool(_minimizeToTrayKey) ?? true;
    } catch (error) {
      debugPrint('Failed to read desktop settings: $error');
    }
    _launchAtStartup = await _readLaunchAtStartup();
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setMinimizeToTray(bool value) async {
    if (_minimizeToTray == value) return;
    _minimizeToTray = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_minimizeToTrayKey, value);
    } catch (error) {
      debugPrint('Failed to persist the minimize behaviour: $error');
    }
  }

  /// Adds or removes the sign-in entry.
  ///
  /// Returns an error message when Windows refused the change, so the caller
  /// can tell the user instead of showing a switch that silently springs back.
  Future<String?> setLaunchAtStartup(bool value) async {
    if (!supportsLaunchAtStartup) {
      return 'Starting at sign-in is only available on Windows';
    }
    if (_launchAtStartup == value) return null;

    try {
      final applied = await _startupChannel.invokeMethod<bool>(
        'setEnabled',
        value,
      );
      _launchAtStartup = applied ?? value;
      notifyListeners();
      return null;
    } on PlatformException catch (error) {
      _launchAtStartup = await _readLaunchAtStartup();
      notifyListeners();
      return error.message ?? 'Windows refused to change the sign-in entry';
    } on MissingPluginException {
      return 'This build does not support starting at sign-in';
    }
  }

  Future<bool> _readLaunchAtStartup() async {
    if (!supportsLaunchAtStartup) return false;
    try {
      return await _startupChannel.invokeMethod<bool>('isEnabled') ?? false;
    } on PlatformException catch (error) {
      debugPrint('Failed to read the sign-in entry: ${error.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
