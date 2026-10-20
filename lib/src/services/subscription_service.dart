import '../ffi/native_proxy_operations.dart';
import '../models/proxy_config.dart';
import 'local_network_service.dart';

/// Rust owns the listener and cached subscription documents on every platform.
class SubscriptionService {
  SubscriptionService({LocalNetworkService? localNetworkService})
    : _localNetworkService = localNetworkService ?? LocalNetworkService();
  final LocalNetworkService _localNetworkService;
  int? _id;
  int _port = 8080;

  Future<void> start(ProxyConfigModel config, int port) async {
    await stop();
    final result = await NativeProxyOperations.shared.run(
      'start_subscription',
      arguments: {
        'port': port,
        'config': {
          'local_port': config.localPort,
          'server_host': config.serverHost,
          'udp_enabled': config.udpEnabled,
          'reverse_geo': config.reverseGeo,
        },
      },
    );
    _id = result['id'] as int;
    _port = result['port'] as int;
  }

  Future<void> stop() async {
    final id = _id;
    if (id == null) return;
    await NativeProxyOperations.shared.run(
      'stop_subscription',
      arguments: {'id': id},
    );
    _id = null;
  }

  Future<String> getClashUrl() async => '${await _getBaseUrl()}/clash';
  Future<String> getShadowrocketUrl({bool base64 = false}) async =>
      '${await _getBaseUrl()}/shadowrocket${base64 ? '/base64' : ''}';
  Future<String> _getBaseUrl() async =>
      await _localNetworkService.getHttpProxyUrl(_port) ??
      'http://127.0.0.1:$_port';
}
