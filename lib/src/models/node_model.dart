import 'upstream_endpoint.dart';

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

  /// What carried the test: TCP to the catalogue address, or QUIC. Results
  /// recorded before the choice existed read as TCP, even for a `quic://`
  /// entry, whose results always travelled over QUIC.
  final UpstreamTransport carrier;

  const NodeVerification({
    required this.status,
    required this.checkedAt,
    this.countryCode = '',
    this.egressIp = '',
    this.latencyMs,
    this.error,
    this.carrier = UpstreamTransport.tcp,
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
    'carrier': carrier.name,
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
      carrier: UpstreamTransport.values.firstWhere(
        (candidate) => candidate.name == value['carrier'],
        orElse: () => UpstreamTransport.tcp,
      ),
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

  /// The address with its carrier, or null when it does not parse. Parsed
  /// once: every carrier, health and current-node check starts here.
  late final UpstreamEndpoint? endpoint = UpstreamEndpoint.tryParse(addr);

  /// The carrier its own address names: QUIC for a `quic://` entry, TCP
  /// otherwise, including an address that does not parse.
  UpstreamTransport get carrier => endpoint?.transport ?? UpstreamTransport.tcp;

  // Parse host and port from addr (format: "ip:port")
  String get host => _parseHostAndPort().$1;
  int get port => _parseHostAndPort().$2;

  (String, int) _parseHostAndPort() {
    final endpoint = UpstreamEndpoint.parse(addr);
    return (endpoint.qualifiedHost, endpoint.port);
  }
}
