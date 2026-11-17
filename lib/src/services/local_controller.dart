import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../ffi/proxy_service.dart';
import '../models/node_model.dart';
import '../models/upstream_endpoint.dart';
import '../providers/proxy_provider.dart';
import 'build_capabilities.dart';
import 'website_rules.dart';

/// A refusal the local API reports with this stable kind.
class _Refused implements Exception {
  const _Refused(this.kind);
  final String kind;
}

/// The desktop app's loopback control API.
///
/// Native code serves HTTP, checks the token and keeps website rules. What
/// only the app knows — its node catalogue, whether the proxy runs, and how
/// to switch — is asked here: [_serve] collects each call with `next` and
/// hands back the answer with the following `next`.
class LocalController extends ChangeNotifier {
  LocalController(this._service, this._proxy, this._rules);

  final ProxyService _service;
  final ProxyState _proxy;
  final WebsiteRules _rules;

  static bool get supported =>
      !BuildCapabilities.usesPacketTunnel &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  int? _id;
  int? _port;
  String? _token;
  String? _error;
  bool _busy = false;
  bool _disposed = false;

  bool get running => _id != null;
  bool get busy => _busy;
  String? get error => _error;

  /// `http://127.0.0.1:<port>` while running.
  String? get url => _port == null ? null : 'http://127.0.0.1:$_port';
  String? get token => _token;

  Future<void> start() async {
    if (_busy || running || _disposed || !supported) return;
    _setBusy(true, clearError: true);
    try {
      final random = Random.secure();
      final token = base64UrlEncode([
        for (var i = 0; i < 32; i++) random.nextInt(256),
      ]).replaceAll('=', '');
      final started = await _service.localController({
        'action': 'start',
        'port': 0,
        'token': token,
      });
      final id = started['id'] as int;
      _id = id;
      _port = started['port'] as int;
      _token = token;
      unawaited(_serve(id));
    } catch (error) {
      _error = _message(error);
    } finally {
      _setBusy(false);
    }
    if (_disposed) await stop();
  }

  Future<void> stop() async {
    final id = _id;
    if (id == null || _busy) return;
    _setBusy(true);
    try {
      await _service.localController({'action': 'stop', 'id': id});
    } catch (error) {
      _error = _message(error);
    } finally {
      _forget(id);
      _setBusy(false);
    }
  }

  Future<void> _serve(int id) async {
    Map<String, Object?>? reply;
    try {
      while (_id == id) {
        final next = await _service.localController({
          'action': 'next',
          'id': id,
          'reply': reply,
        });
        final call = next['call'];
        if (call is! Map) break;
        reply = await _answer(call);
      }
    } catch (error) {
      _error = _message(error);
    }
    // The native service is gone; stop() may already have said so.
    if (_id == id) {
      _forget(id);
      _notify();
    }
  }

  Future<Map<String, Object?>> _answer(Map<dynamic, dynamic> call) async {
    try {
      final Object? answer = switch (call['operation']) {
        'nodes' => {'nodes': _nodes()},
        'status' => _status(),
        'switch' => await _switch(call),
        'rules_changed' => _rulesChanged(call),
        _ => throw const _Refused('invalid_request'),
      };
      return {'Ok': answer};
    } on _Refused catch (refused) {
      return {'Err': refused.kind};
    } catch (error, stack) {
      debugPrint('Local controller call failed: $error\n$stack');
      return {'Err': 'unavailable'};
    }
  }

  List<Map<String, Object?>> _nodes() => [
    for (final node in _proxy.nodes)
      if (_proxy.endpointsOf(node) case final endpoints
          when endpoints.isNotEmpty)
        {
          'id': node.nodeId,
          'endpoints': [for (final e in endpoints) _endpoint(e)],
        },
  ];

  Map<String, Object?> _status() {
    final endpoint = _proxy.isRunning ? _proxy.configuredEndpoint : null;
    return {
      'running': _proxy.isRunning,
      'local_port': _proxy.isRunning ? _proxy.config.localPort : null,
      'active': endpoint == null
          ? null
          : {
              'node_id': _proxy.nodes
                  .where((node) => _proxy.isInUse(node, endpoint.transport))
                  .firstOrNull
                  ?.nodeId,
              'endpoint': _endpoint(endpoint),
            },
    };
  }

  Future<Map<String, Object?>> _switch(Map<dynamic, dynamic> call) async {
    if (_proxy.isProxyOperationInProgress || _proxy.isTunBusy) {
      throw const _Refused('busy');
    }
    if (!_proxy.isRunning) throw const _Refused('not_running');
    final NodeInfo node =
        _proxy.nodes.where((n) => n.nodeId == call['node_id']).firstOrNull ??
        (throw const _Refused('unknown_node'));
    final transport = UpstreamTransport.values.byName(
      call['transport'] as String,
    );
    if (_proxy.endpointOf(node, transport) == null) {
      throw const _Refused('unsupported_transport');
    }
    final bool switched;
    try {
      switched = await _proxy.switchToNode(
        node,
        carrier: transport,
        closeExisting: call['close_existing'] == true,
      );
    } catch (error) {
      debugPrint('Local controller switch failed: $error');
      throw const _Refused('switch_failed');
    }
    if (!switched) throw const _Refused('switch_failed');
    return _status();
  }

  Object? _rulesChanged(Map<dynamic, dynamic> call) {
    _rules.replace(call);
    return null;
  }

  static Map<String, Object?> _endpoint(UpstreamEndpoint endpoint) => {
    'host': endpoint.host,
    'port': endpoint.port,
    'transport': endpoint.transport.name,
  };

  static String _message(Object error) =>
      error is StateError ? error.message : error.toString();

  void _forget(int id) {
    if (_id != id) return;
    _id = null;
    _port = null;
    _token = null;
  }

  void _setBusy(bool busy, {bool clearError = false}) {
    _busy = busy;
    if (clearError) _error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
