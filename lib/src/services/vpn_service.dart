import 'dart:io';
import 'package:flutter/services.dart';

class VpnService {
  static const MethodChannel _channel = MethodChannel(
    'com.proxyui.proxy_ui/vpn',
  );

  /// Check if VPN is supported on this platform
  static bool get isSupported => Platform.isAndroid;

  /// Check if VPN permission is granted
  Future<bool> isPermissionGranted() async {
    if (!isSupported) return false;

    try {
      final result = await _channel.invokeMethod<bool>('prepare');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Start VPN service
  /// Returns true if VPN was started successfully
  Future<bool> start() async {
    if (!isSupported) {
      throw UnsupportedError('VPN is only supported on Android');
    }

    try {
      final result = await _channel.invokeMethod<bool>('start');
      return result ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        throw VpnPermissionDeniedException();
      }
      rethrow;
    }
  }

  /// Stop VPN service
  Future<bool> stop() async {
    if (!isSupported) return false;

    try {
      final result = await _channel.invokeMethod<bool>('stop');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Check if VPN is currently running
  Future<bool> isRunning() async {
    if (!isSupported) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isRunning');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Set up method call handler for VPN events
  void setMethodCallHandler(Future<dynamic> Function(MethodCall call) handler) {
    _channel.setMethodCallHandler(handler);
  }
}

class VpnPermissionDeniedException implements Exception {
  @override
  String toString() => 'VPN permission was denied by user';
}
