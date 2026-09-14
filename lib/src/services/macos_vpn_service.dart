import 'dart:async';
import 'package:flutter/services.dart';

class MacosVpnService {
  static const _channel = MethodChannel('com.proxyui/macos_vpn');
  static const _events = EventChannel('com.proxyui/macos_vpn/events');
  final _changes = StreamController<void>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;
  bool running = false;
  String? lastError;

  Stream<void> get changes => _changes.stream;

  Future<void> initialize() async {
    _subscription ??= _events.receiveBroadcastStream().listen(
      _apply,
      onError: (Object error) {
        if (_disposed) return;
        lastError = error is PlatformException
            ? error.message
            : error.toString();
        _changes.add(null);
      },
    );
    _apply(await _channel.invokeMapMethod<String, dynamic>('initialize'));
  }

  void _apply(dynamic event) {
    if (_disposed || event is! Map) return;
    running = event['running'] == true;
    lastError = event['error'] as String?;
    _changes.add(null);
  }

  Future<void> start(Map<String, dynamic> configuration) async {
    lastError = null;
    _apply(
      await _channel.invokeMapMethod<String, dynamic>('start', configuration),
    );
  }

  Future<void> stop() async {
    _apply(await _channel.invokeMapMethod<String, dynamic>('stop'));
  }

  static Future<void> openLogs(String path) =>
      _channel.invokeMethod('openLogs', path);

  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    unawaited(_changes.close());
  }
}
