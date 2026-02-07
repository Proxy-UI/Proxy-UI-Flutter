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
  String get host => _parseHostAndPort().$1;
  int get port => _parseHostAndPort().$2;

  (String, int) _parseHostAndPort() {
    final value = addr.trim();
    if (value.isEmpty) {
      throw const FormatException('Address is empty');
    }

    if (value.startsWith('[')) {
      final endBracket = value.indexOf(']');
      if (endBracket <= 1 || endBracket >= value.length - 2) {
        throw FormatException('Invalid address format: $value');
      }
      if (value[endBracket + 1] != ':') {
        throw FormatException('Invalid address format: $value');
      }
      final hostPart = value.substring(1, endBracket);
      final portPart = value.substring(endBracket + 2);
      final parsedPort = int.tryParse(portPart);
      if (parsedPort == null || parsedPort < 1 || parsedPort > 65535) {
        throw FormatException('Invalid port: $portPart');
      }
      return (hostPart, parsedPort);
    }

    final separatorIndex = value.lastIndexOf(':');
    if (separatorIndex <= 0 || separatorIndex >= value.length - 1) {
      throw FormatException('Invalid address format: $value');
    }
    final hostPart = value.substring(0, separatorIndex);
    final portPart = value.substring(separatorIndex + 1);
    final parsedPort = int.tryParse(portPart);
    if (parsedPort == null || parsedPort < 1 || parsedPort > 65535) {
      throw FormatException('Invalid port: $portPart');
    }
    return (hostPart, parsedPort);
  }

  // Generate ProxyConfigModel for this node
  ProxyConfigModel toProxyConfig({
    int localPort = 1080,
    String? sessionKey,
    bool autoProxy = true,
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
      reverseGeo: reverseGeo,
      needCodecIps: needCodecIps,
      forceCodec: forceCodec,
      setSystemProxy: setSystemProxy,
    );
  }
}
