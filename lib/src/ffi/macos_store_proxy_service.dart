import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../services/macos_vpn_service.dart';
import 'proxy_ffi.dart';
import 'proxy_service.dart';

/// Store builds run forwarding inside the packet provider. Inherited FFI
/// methods still handle the node catalogue and probes in the containing app.
class MacosStoreProxyService extends ProxyService {
  final MacosVpnService _vpn;
  String? _error;
  int _localPort = 10801;

  MacosStoreProxyService({MacosVpnService? vpn})
    : _vpn = vpn ?? MacosVpnService();

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
    bool udpEnabled = true,
    bool udpDirectFallback = true,
    bool tunEnabled = false,
    List<String> tunBypassProcesses = const [],
    bool reverseGeo = false,
    String? needCodecIps,
    bool forceCodec = false,
    bool setSystemProxy = false,
    bool allowLan = false,
  }) async {
    _error = null;
    try {
      await _vpn.start({
        'serverHost': serverHost,
        'serverPort': serverPort,
        'localPort': localPort,
        'sessionKey': sessionKey,
        'autoProxy': false,
        'udpEnabled': udpEnabled,
        'udpDirectFallback': udpDirectFallback,
        'reverseGeo': false,
        'needCodecIps': needCodecIps,
        'forceCodec': forceCodec,
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
  int switchUpstream({required String serverHost, required int serverPort}) =>
      ProxyResult.invalidParam;
  @override
  int setTunBypassProcesses(List<String> processes) => ProxyResult.invalidParam;
  @override
  List<String> listTunProcesses() => const [];
  @override
  List<TunProcessInfo> listTunProcessDetails() => const [];

  @override
  Future<int?> testLatency({String? testUrl, int timeoutMs = 10000}) async {
    if (!isRunning) throw StateError('VPN is not connected.');
    final client = HttpClient()
      ..connectionTimeout = Duration(milliseconds: timeoutMs)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$_localPort';
    final watch = Stopwatch()..start();
    try {
      return await (() async {
        final request = await client.getUrl(
          Uri.parse(testUrl ?? 'https://www.gstatic.com/generate_204'),
        );
        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode >= 400) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        return watch.elapsedMilliseconds;
      })().timeout(Duration(milliseconds: timeoutMs));
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    _vpn.dispose();
    super.dispose();
  }
}
