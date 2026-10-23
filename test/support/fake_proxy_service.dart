import 'dart:convert';

import 'package:proxy_ui/src/ffi/proxy_ffi.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/models/node_catalog_preferences.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/models/socks5_link.dart';

/// A proxy service that never touches native code, the network or routes.
class FakeProxyService extends ProxyService {
  FakeProxyService({this.probes = const {}, this.socks5Links = const {}});

  /// Answers to node probes, by address; anything else does not answer.
  final Map<String, NodeProbe> probes;

  /// SOCKS5 links by node address; other nodes serve none.
  final Map<String, Socks5Link> socks5Links;
  final calls = <String>[];
  bool _running = false;
  bool _tunRunning = false;
  String? _lastError;

  /// Whether TUN follows a switch to another host in place, as on Windows.
  @override
  bool supportsLiveTunSwitch = false;

  /// What [switchUpstream] answers, and the runtime's reason when it refuses.
  int switchResult = ProxyResult.ok;
  String? switchError;

  @override
  void initLogging() {}
  @override
  void setLogLevel(int level) {}
  @override
  bool restoreOrphanedSystemProxy() => false;

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
    bool tunFakeIp = false,
    String tunDnsServer = '223.5.5.5',
    List<String> tunBypassProcesses = const [],
    bool reverseGeo = false,
    bool secureTransport = false,
    bool setSystemProxy = false,
    bool allowLan = false,
  }) async {
    calls.add('start $serverHost:$serverPort');
    _running = true;
    return ProxyResult.ok;
  }

  @override
  Future<int> startTun(List<String> processes) async {
    calls.add('startTun');
    _tunRunning = true;
    return ProxyResult.ok;
  }

  @override
  Future<int> stopTun() async {
    calls.add('stopTun');
    _tunRunning = false;
    return ProxyResult.ok;
  }

  @override
  Future<int> switchUpstream({
    required String serverHost,
    required int serverPort,
  }) async {
    calls.add('switch $serverHost:$serverPort');
    _lastError = switchResult == ProxyResult.ok ? null : switchError;
    return switchResult;
  }

  @override
  Future<int> stop() async {
    calls.add('stop');
    _running = _tunRunning = false;
    return ProxyResult.ok;
  }

  @override
  Future<NodeProbe> probeNode({
    required String serverHost,
    required int serverPort,
    bool secureTransport = false,
    int timeoutMs = 10000,
  }) async {
    calls.add('probe $serverHost:$serverPort');
    return probes['$serverHost:$serverPort'] ??
        const NodeProbe(success: false, error: 'no answer');
  }

  @override
  Future<Socks5Link?> getSocks5Link({
    required String serverHost,
    required int serverPort,
    String? sessionKey,
    int timeoutMs = 5000,
  }) async {
    calls.add('socks5 $serverHost:$serverPort');
    return socks5Links['$serverHost:$serverPort'];
  }

  @override
  bool get isRunning => _running;
  @override
  bool get isTunRunning => _tunRunning;
  @override
  bool get isElevated => true;
  @override
  String? get lastError => _lastError;
  @override
  void dispose() {}
}

/// A catalogue shaped like a real one: most nodes in a few countries, a
/// handful elsewhere, and a cluster that never answered. Addresses come from
/// the documentation ranges, so none of them is anybody's server.
NodeCatalogPreferences sampleCatalogue() {
  final seen = DateTime.now().subtract(const Duration(minutes: 7));
  final checked = DateTime.now().subtract(const Duration(minutes: 3));
  final nodes = <NodeInfo>[];
  final verifications = <String, NodeVerification>{};
  var octet = 10;
  void add(
    String country,
    List<int?> latencies, {
    String prefix = '203.0.113',
  }) {
    for (final latency in latencies) {
      final addr = '$prefix.${octet++}:1081';
      final node = NodeInfo(
        nodeId: addr,
        addr: addr,
        lastSeen: seen,
        country: '',
        region: '',
      );
      nodes.add(node);
      verifications[node.storageKey] = latency == null
          ? NodeVerification(
              status: NodeVerificationStatus.unreachable,
              checkedAt: checked,
              error: 'response: the node closed the tunnel without sending anything',
            )
          : NodeVerification(
              status: NodeVerificationStatus.verified,
              checkedAt: checked,
              countryCode: country,
              egressIp: addr.split(':').first,
              latencyMs: latency,
            );
    }
  }

  add('US', [
    131,
    187,
    213,
    359,
    367,
    439,
    464,
    469,
    472,
    498,
    526,
    553,
    610,
    647,
    727,
  ]);
  add('HK', [128, 136, 138, 147, 192, 255], prefix: '198.51.100');
  add('SG', [255, 527, 564, 591], prefix: '198.51.100');
  add('JP', [142, 205, 318], prefix: '198.51.100');
  add('DE', [612, 680], prefix: '192.0.2');
  add('GB', [584, 778], prefix: '192.0.2');
  add('KR', [190], prefix: '192.0.2');
  add('AE', [615], prefix: '192.0.2');
  add('PL', [564], prefix: '192.0.2');
  add('', [null, null, null, null, null, null, null, null], prefix: '192.0.2');
  // Two that were never tested.
  for (final addr in ['192.0.2.200:1081', '192.0.2.201:1081']) {
    nodes.add(
      NodeInfo(
        nodeId: addr,
        addr: addr,
        lastSeen: seen,
        country: '',
        region: '',
      ),
    );
  }
  final latencies = {
    for (final entry in verifications.entries)
      if (entry.value.latencyMs != null) entry.key: entry.value.latencyMs!,
  };
  return NodeCatalogPreferences(
    serverHost: '203.0.113.10',
    nodes: nodes,
    fetchedAt: checked,
    verifications: verifications,
    latencies: latencies,
  );
}

/// Shared preferences holding [catalogue], connected through [current].
Map<String, Object> samplePreferences(
  NodeCatalogPreferences catalogue, {
  String? current,
}) => {
  'node_catalog_preferences': jsonEncode(catalogue.toJson()),
  if (current != null)
    'proxy_config': jsonEncode({
      'serverHost': current.split(':').first,
      'serverPort': int.parse(current.split(':').last),
      'localPort': 1080,
      'setSystemProxy': false,
    }),
};
