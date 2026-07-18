import 'proxy_config.dart';

/// Node information with geo location.
class NodeInfo {
  final String nodeId;
  final String addr;
  final DateTime lastSeen;
  final String country;
  final String region;
  int? latencyMs; // Only populated for currently running node

  NodeInfo({
    required this.nodeId,
    required this.addr,
    required this.lastSeen,
    required this.country,
    required this.region,
    this.latencyMs,
  });

  String get displayName => '$country - $region';
  String get latencyDisplay => latencyMs != null ? '${latencyMs}ms' : 'N/A';

  // Parse host and port from addr (format: "ip:port")
  String get host => addr.split(':').first;
  int get port => int.parse(addr.split(':').last);

  // Generate ProxyConfigModel for this node
  ProxyConfigModel toProxyConfig({
    int localPort = 1080,
    String? sessionKey,
    bool autoProxy = true,
    bool udpEnabled = true,
    bool tunEnabled = false,
    List<String> tunBypassProcesses = const [],
    bool reverseGeo = false,
    String? needCodecIps,
    bool forceCodec = false,
    bool? setSystemProxy,
  }) {
    return ProxyConfigModel(
      serverHost: host,
      serverPort: port,
      localPort: localPort,
      sessionKey: sessionKey,
      autoProxy: autoProxy,
      udpEnabled: udpEnabled,
      tunEnabled: tunEnabled,
      tunBypassProcesses: tunBypassProcesses,
      reverseGeo: reverseGeo,
      needCodecIps: needCodecIps,
      forceCodec: forceCodec,
      setSystemProxy: setSystemProxy,
    );
  }
}
