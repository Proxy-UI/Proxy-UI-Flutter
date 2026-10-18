import 'proxy_config.dart';

/// Outcome of asking an echo service, through a node, where its traffic leaves
/// from.
enum NodeVerificationStatus {
  /// The node answered and the echo service named a country.
  verified,

  /// The node could not be reached, or it refused to carry the request.
  unreachable,
}

/// A recorded verification, kept so the catalogue can show a real egress
/// country rather than the one the server registered itself under.
class NodeVerification {
  final NodeVerificationStatus status;

  /// ISO 3166-1 alpha-2 as seen from outside. Empty when unreachable.
  final String countryCode;

  /// The address the echo service saw. Empty when unreachable.
  final String egressIp;
  final int? latencyMs;
  final String? error;
  final DateTime checkedAt;

  const NodeVerification({
    required this.status,
    required this.checkedAt,
    this.countryCode = '',
    this.egressIp = '',
    this.latencyMs,
    this.error,
  });

  bool get isVerified => status == NodeVerificationStatus.verified;

  /// True when the echo service disagrees with the catalogue's country.
  bool disagreesWith(String catalogCountry) {
    if (!isVerified || countryCode.isEmpty) return false;
    final claimed = catalogCountry.trim().toUpperCase();
    return claimed.isNotEmpty && claimed != countryCode;
  }

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'countryCode': countryCode,
    'egressIp': egressIp,
    'latencyMs': latencyMs,
    'error': error,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
  };

  static NodeVerification? fromJson(Object? value) {
    if (value is! Map) return null;
    final checkedAt = DateTime.tryParse(value['checkedAt']?.toString() ?? '');
    if (checkedAt == null) return null;
    final status = NodeVerificationStatus.values.firstWhere(
      (candidate) => candidate.name == value['status'],
      orElse: () => NodeVerificationStatus.unreachable,
    );
    final latency = value['latencyMs'];
    return NodeVerification(
      status: status,
      checkedAt: checkedAt.toLocal(),
      countryCode: value['countryCode'] is String
          ? (value['countryCode'] as String).toUpperCase()
          : '',
      egressIp: value['egressIp'] is String ? value['egressIp'] as String : '',
      latencyMs: latency is int && latency >= 0 ? latency : null,
      error: value['error'] is String ? value['error'] as String : null,
    );
  }
}

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

  /// Stable identity for persisted per-node data.
  ///
  /// A node keeps its id across catalogue refreshes, but the same id can be
  /// re-pointed at a different address, so both take part.
  String get storageKey => '$nodeId\x00$addr';

  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'addr': addr,
    'lastSeen': lastSeen.toUtc().toIso8601String(),
    'country': country,
    'region': region,
  };

  static NodeInfo? fromJson(Object? value) {
    if (value is! Map) return null;
    final nodeId = value['nodeId'];
    final addr = value['addr'];
    if (nodeId is! String || addr is! String || addr.isEmpty) return null;
    return NodeInfo(
      nodeId: nodeId,
      addr: addr,
      lastSeen:
          DateTime.tryParse(value['lastSeen']?.toString() ?? '')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      country: value['country'] is String ? value['country'] as String : '',
      region: value['region'] is String ? value['region'] as String : '',
    );
  }

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
    bool allowLan = false,
    String? sessionKey,
    bool autoProxy = true,
    bool udpEnabled = false,
    bool udpDirectFallback = true,
    bool tunEnabled = false,
    bool tunFakeIp = false,
    String tunDnsServer = '223.5.5.5',
    List<String> tunBypassProcesses = const [],
    bool? tunBypassWeGame,
    AndroidVpnRoutingMode androidVpnRoutingMode = AndroidVpnRoutingMode.all,
    List<String> androidVpnPackages = const [],
    bool reverseGeo = false,
    bool secureTransport = false,
    bool? setSystemProxy,
  }) {
    return ProxyConfigModel(
      serverHost: host,
      serverPort: port,
      localPort: localPort,
      allowLan: allowLan,
      sessionKey: sessionKey,
      autoProxy: autoProxy,
      udpEnabled: udpEnabled,
      udpDirectFallback: udpDirectFallback,
      tunEnabled: tunEnabled,
      tunFakeIp: tunFakeIp,
      tunDnsServer: tunDnsServer,
      tunBypassProcesses: tunBypassProcesses,
      tunBypassWeGame: tunBypassWeGame,
      androidVpnRoutingMode: androidVpnRoutingMode,
      androidVpnPackages: androidVpnPackages,
      reverseGeo: reverseGeo,
      secureTransport: secureTransport,
      setSystemProxy: setSystemProxy,
    );
  }
}
