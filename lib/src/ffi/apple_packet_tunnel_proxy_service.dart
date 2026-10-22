import 'dart:async';

import 'package:flutter/services.dart';

import '../services/apple_vpn_service.dart';
import '../services/build_capabilities.dart';
import 'proxy_ffi.dart';
import 'proxy_service.dart';
import 'native_proxy_operations.dart';

/// Apple VPN builds run forwarding inside the packet provider. Inherited FFI
/// methods handle the catalogue and disconnected probes in the containing app.
/// Connected probes run in the provider so they cannot re-enter the VPN.
class ApplePacketTunnelProxyService extends ProxyService {
  final AppleVpnService _vpn;
  String? _error;
  int _localPort = 10801;

  ApplePacketTunnelProxyService({AppleVpnService? vpn})
    : _vpn = vpn ?? AppleVpnService();

  @override
  Stream<void> get connectionChanges => _vpn.changes;
  @override
  Future<void> initializePlatform() => _vpn.initialize();
  @override
  bool restoreOrphanedSystemProxy() => false;
  @override
  bool get isRunning => _vpn.running;
  @override
  bool get isTunRunning => _vpn.running;
  @override
  String? get lastError => _vpn.running ? null : _vpn.lastError ?? _error;

  @override
  Future<int> start({
    required String serverHost,
    required int serverPort,
    int localPort = 1080,
    String? sessionKey,
    bool autoProxy = true,
    bool udpEnabled = false,
    bool udpDirectFallback = false,
    bool tunEnabled = false,
    bool tunFakeIp = false,
    String tunDnsServer = '8.8.8.8',
    List<String> tunBypassProcesses = const [],
    bool reverseGeo = false,
    bool secureTransport = false,
    bool setSystemProxy = false,
    bool allowLan = false,
  }) async {
    _error = null;
    if (secureTransport) {
      _error = 'V3 transport is not supported by this packet-tunnel build';
      return ProxyResult.invalidParam;
    }
    try {
      await _vpn.start({
        'serverHost': serverHost,
        'serverPort': serverPort,
        'localPort': localPort,
        'sessionKey': sessionKey,
        'autoProxy': !BuildCapabilities.isMacAppStore && autoProxy,
        'udpEnabled': udpEnabled,
        'tunFakeIp': tunFakeIp,
        'tunDnsServer': tunDnsServer,
        // Legacy field cannot override the provider's fixed country policy.
        'udpDirectFallback': false,
        'reverseGeo': !BuildCapabilities.isMacAppStore && reverseGeo,
      });
      _localPort = localPort;
      return isRunning ? ProxyResult.ok : ProxyResult.runtimeError;
    } on PlatformException catch (error) {
      _error = error.message ?? error.code;
      return ProxyResult.runtimeError;
    }
  }

  @override
  Future<int> stop() async {
    _error = null;
    try {
      await _vpn.stop();
      return isRunning ? ProxyResult.runtimeError : ProxyResult.ok;
    } on PlatformException catch (error) {
      _error = error.message ?? error.code;
      return ProxyResult.runtimeError;
    }
  }

  @override
  Future<int> startTun(List<String> processes) async =>
      isRunning ? ProxyResult.ok : ProxyResult.notRunning;
  @override
  Future<int> stopTun() => stop();
  @override
  Future<int> switchUpstream({
    required String serverHost,
    required int serverPort,
  }) async => ProxyResult.invalidParam;
  @override
  int setTunBypassProcesses(List<String> processes) => ProxyResult.invalidParam;
  @override
  List<String> listTunProcesses() => const [];
  @override
  Future<List<TunProcessInfo>> listTunProcessDetails() async => const [];

  @override
  Future<int?> testLatency({String? testUrl, int timeoutMs = 10000}) async {
    if (!isRunning) throw StateError('VPN is not connected.');
    final result = await NativeProxyOperations.shared.run(
      'http_latency',
      arguments: {
        'proxy_port': _localPort,
        'test_url': testUrl ?? 'https://www.gstatic.com/generate_204',
        'timeout_ms': timeoutMs,
      },
    );
    return result['latencyMs'] as int;
  }

  @override
  Future<NodeProbe> probeNode({
    required String serverHost,
    required int serverPort,
    bool secureTransport = false,
    int timeoutMs = 10000,
  }) => isRunning
      ? _probeInProvider(
          (host: serverHost, port: serverPort),
          secureTransport: secureTransport,
          timeoutMs: timeoutMs,
        )
      : super.probeNode(
          serverHost: serverHost,
          serverPort: serverPort,
          secureTransport: secureTransport,
          timeoutMs: timeoutMs,
        );

  Future<NodeProbe> _probeInProvider(
    NodeProbeTarget target, {
    required bool secureTransport,
    required int timeoutMs,
  }) async {
    try {
      final result = await _vpn.probeNode(
        host: target.host,
        port: target.port,
        secureTransport: secureTransport,
        timeoutMs: timeoutMs,
      );
      return NodeProbe(
        success: result['success'] == true,
        countryCode: result['countryCode'] as String? ?? '',
        egressIp: result['egressIp'] as String? ?? '',
        latencyMs: result['latencyMs'] as int?,
        error: result['error'] as String?,
      );
    } catch (error) {
      return NodeProbe(success: false, error: error.toString());
    }
  }

  @override
  Stream<(int, NodeProbe)> probeNodes(
    List<NodeProbeTarget> targets, {
    bool secureTransport = false,
    int timeoutMs = 10000,
  }) {
    if (!isRunning) {
      return super.probeNodes(
        targets,
        secureTransport: secureTransport,
        timeoutMs: timeoutMs,
      );
    }
    // Keep one route for the whole batch, including across disconnects. Falling
    // back into the app midway would mix tunneled and direct measurements.
    late final StreamController<(int, NodeProbe)> results;
    var cancelled = false;
    results = StreamController(
      onCancel: () => cancelled = true,
      onListen: () {
        var next = 0;
        Future<void> worker() async {
          while (!cancelled && next < targets.length) {
            final index = next++;
            final probe = await _probeInProvider(
              targets[index],
              secureTransport: secureTransport,
              timeoutMs: timeoutMs,
            );
            if (!cancelled) results.add((index, probe));
          }
        }

        Future.wait([
          for (var i = 0; i < targets.length && i < 4; i++) worker(),
        ]).whenComplete(results.close);
      },
    );
    return results.stream;
  }

  @override
  void dispose() {
    _vpn.dispose();
    super.dispose();
  }
}
