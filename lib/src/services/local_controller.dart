import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../ffi/native_proxy_operations.dart';
import 'build_capabilities.dart';

/// Rust owns the authenticated HTTP listener. Only the provider that owns the
/// live proxy can resolve a catalogue ID and commit a selection.
class LocalController {
  LocalController(this.dispatch, this.changed);
  final Future<Map<String, Object?>> Function(Map<String, dynamic>) dispatch;
  final void Function() changed;
  static bool get supported =>
      !BuildCapabilities.usesPacketTunnel &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  int? _id;
  String? token;
  int? port;
  String? error;
  bool busy = false;
  bool _disposed = false;
  bool get running => _id != null;

  Future<Map<String, dynamic>> _request(Map<String, Object?> request) =>
      NativeProxyOperations.shared.run(
        'external_controller',
        arguments: {'request': request},
      );

  Future<void> start() async {
    if (busy || running || _disposed || !supported) return;
    busy = true;
    error = null;
    changed();
    try {
      final random = Random.secure();
      final secret = base64UrlEncode(
        List.generate(32, (_) => random.nextInt(256)),
      );
      final result = await _request({
        'action': 'start',
        'port': 0,
        'token': secret,
      });
      final id = result['id'] as int;
      _id = id;
      token = secret;
      port = result['port'] as int;
      unawaited(_serve(id));
    } catch (failure) {
      error = failure.toString();
    } finally {
      busy = false;
      changed();
      if (_disposed) await stop();
    }
  }

  Future<void> _serve(int id) async {
    Map<String, Object?>? reply;
    try {
      while (_id == id && !_disposed) {
        final result = await _request({
          'action': 'exchange',
          'id': id,
          'reply': reply,
        });
        final command = result['command'];
        if (command == null || _id != id || busy || _disposed) break;
        try {
          reply = await dispatch(command as Map<String, dynamic>);
        } catch (_) {
          reply = {'Err': 'switch_failed'};
        }
      }
    } catch (failure) {
      error = failure.toString();
    } finally {
      if (_id == id && !busy) await stop();
    }
  }

  Future<void> stop() async {
    final id = _id;
    if (id == null || busy) return;
    busy = true;
    changed();
    try {
      await _request({'action': 'stop', 'id': id});
      _id = null;
      token = null;
      port = null;
    } catch (failure) {
      error = failure.toString();
    } finally {
      busy = false;
      changed();
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(stop());
  }
}
