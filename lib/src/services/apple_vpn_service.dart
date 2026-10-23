import 'dart:async';

import 'package:flutter/services.dart';

class AppleVpnService {
  static const _channel = MethodChannel('com.proxyui/apple_vpn');
  static const _events = EventChannel('com.proxyui/apple_vpn/events');
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

  Future<void> switchUpstream(String host, int port) async {
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'switchUpstream',
      {'operation': 'switchUpstream', 'host': host, 'port': port},
    );
    if (response?['success'] != true) {
      throw StateError(
        response?['error']?.toString() ?? 'VPN upstream switch failed',
      );
    }
  }

  Future<Map<String, dynamic>> probeNode({
    required String host,
    required int port,
    required bool secureTransport,
    required int timeoutMs,
  }) async {
    final deadline = timeoutMs.clamp(1, 30000);
    final response = await _channel
        .invokeMapMethod<String, dynamic>('probeNode', {
          'operation': 'probeNode',
          'host': host,
          'port': port,
          'protocol': secureTransport ? 3 : 0,
          'timeoutMs': deadline,
        })
        .timeout(Duration(milliseconds: deadline + 2000));
    if (response == null) throw StateError('VPN probe response is unavailable');
    return response;
  }

  static Future<void> openLogs(String path) =>
      _channel.invokeMethod('openLogs', path);

  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    unawaited(_changes.close());
  }
}
