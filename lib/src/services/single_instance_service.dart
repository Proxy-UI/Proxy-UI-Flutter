import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'tray_service.dart';

/// Receives activation requests from the Windows runner's single-instance
/// guard.
///
/// The runner refuses to start a second copy of the app; it hands the launch
/// over to the running process, which raises its window instead. See
/// `windows/runner/single_instance.cpp`.
class SingleInstanceService {
  SingleInstanceService._();

  static final SingleInstanceService instance = SingleInstanceService._();

  static const MethodChannel _channel = MethodChannel(
    'proxy_ui/single_instance',
  );

  /// True on platforms whose runner participates in the guard.
  static bool get isSupported => Platform.isWindows;

  bool _initialized = false;

  void initialize() {
    if (_initialized || !isSupported) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'onSecondInstance') return;
    await _activate();
  }

  Future<void> _activate() async {
    try {
      await TrayService.instance.showWindow();
    } catch (error) {
      debugPrint('Failed to raise the window for a second launch: $error');
    }
    // Relaunching the app is how users react to a missing tray icon, so treat
    // it as a request to recreate the notification icon as well.
    unawaited(TrayService.instance.rebuild());
  }
}
