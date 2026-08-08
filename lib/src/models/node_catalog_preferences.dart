import 'node_model.dart';

/// Persisted settings and latency samples for the node catalog.
class NodeCatalogPreferences {
  final String serverHost;
  final int serverPort;
  final String? sessionKey;
  final bool sortByLatency;
  final Map<String, int> latencies;

  /// The last catalogue fetched from the server.
  ///
  /// Persisted so opening the nodes page shows the servers immediately instead
  /// of an empty list and a round trip. Refreshing stays an explicit action.
  final List<NodeInfo> nodes;
  final DateTime? fetchedAt;

  /// Egress verifications, keyed by [NodeInfo.storageKey].
  final Map<String, NodeVerification> verifications;

  const NodeCatalogPreferences({
    this.serverHost = '',
    this.serverPort = 1081,
    this.sessionKey,
    this.sortByLatency = false,
    this.latencies = const {},
    this.nodes = const [],
    this.fetchedAt,
    this.verifications = const {},
  });

  factory NodeCatalogPreferences.fromJson(Map<String, dynamic> json) {
    final rawPort = json['serverPort'];
    final port = rawPort is int && rawPort >= 1 && rawPort <= 65535
        ? rawPort
        : 1081;
    final rawLatencies = json['latencies'];
    final latencies = <String, int>{};
    if (rawLatencies is Map) {
      for (final entry in rawLatencies.entries) {
        final latency = entry.value;
        if (entry.key is String && latency is int && latency >= 0) {
          latencies[entry.key as String] = latency;
        }
      }
    }

    final nodes = <NodeInfo>[];
    final rawNodes = json['nodes'];
    if (rawNodes is List) {
      for (final entry in rawNodes) {
        final node = NodeInfo.fromJson(entry);
        if (node != null) nodes.add(node);
      }
    }

    final verifications = <String, NodeVerification>{};
    final rawVerifications = json['verifications'];
    if (rawVerifications is Map) {
      for (final entry in rawVerifications.entries) {
        final key = entry.key;
        final verification = NodeVerification.fromJson(entry.value);
        if (key is String && verification != null) {
          verifications[key] = verification;
        }
      }
    }

    return NodeCatalogPreferences(
      serverHost: json['serverHost'] is String
          ? json['serverHost'] as String
          : '',
      serverPort: port,
      sessionKey: json['sessionKey'] is String
          ? json['sessionKey'] as String
          : null,
      sortByLatency: json['sortByLatency'] == true,
      latencies: Map.unmodifiable(latencies),
      nodes: List.unmodifiable(nodes),
      fetchedAt: DateTime.tryParse(
        json['fetchedAt']?.toString() ?? '',
      )?.toLocal(),
      verifications: Map.unmodifiable(verifications),
    );
  }

  /// Reads the two preference payloads used by earlier mobile/desktop builds.
  factory NodeCatalogPreferences.fromLegacyJson({
    required Map<String, dynamic> server,
    required Map<String, dynamic> latencies,
  }) {
    final port = server['port'];
    return NodeCatalogPreferences(
      serverHost: server['host'] is String ? server['host'] as String : '',
      serverPort: port is int && port >= 1 && port <= 65535 ? port : 1081,
      sessionKey: server['sessionKey'] is String
          ? server['sessionKey'] as String
          : null,
      latencies: Map.unmodifiable({
        for (final entry in latencies.entries)
          if (entry.value is int && (entry.value as int) >= 0)
            entry.key: entry.value as int,
      }),
    );
  }

  Map<String, dynamic> toJson() => {
    'serverHost': serverHost,
    'serverPort': serverPort,
    'sessionKey': sessionKey,
    'sortByLatency': sortByLatency,
    'latencies': latencies,
    'nodes': nodes.map((node) => node.toJson()).toList(),
    'fetchedAt': fetchedAt?.toUtc().toIso8601String(),
    'verifications': {
      for (final entry in verifications.entries) entry.key: entry.value.toJson(),
    },
  };

  NodeCatalogPreferences copyWith({
    String? serverHost,
    int? serverPort,
    String? sessionKey,
    bool? sortByLatency,
    Map<String, int>? latencies,
    List<NodeInfo>? nodes,
    DateTime? fetchedAt,
    Map<String, NodeVerification>? verifications,
  }) => NodeCatalogPreferences(
    serverHost: serverHost ?? this.serverHost,
    serverPort: serverPort ?? this.serverPort,
    sessionKey: sessionKey ?? this.sessionKey,
    sortByLatency: sortByLatency ?? this.sortByLatency,
    latencies: latencies ?? this.latencies,
    nodes: nodes ?? this.nodes,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    verifications: verifications ?? this.verifications,
  );

  /// Replaces the cached catalogue, dropping verifications for nodes the server
  /// no longer lists so the store cannot grow without bound.
  NodeCatalogPreferences withCatalog(List<NodeInfo> catalog, DateTime at) {
    final live = catalog.map((node) => node.storageKey).toSet();
    return copyWith(
      nodes: List.unmodifiable(catalog),
      fetchedAt: at,
      verifications: Map.unmodifiable({
        for (final entry in verifications.entries)
          if (live.contains(entry.key)) entry.key: entry.value,
      }),
    );
  }

  NodeVerification? verificationFor(NodeInfo node) =>
      verifications[node.storageKey];

  NodeCatalogPreferences withVerification(
    NodeInfo node,
    NodeVerification verification,
  ) {
    return copyWith(
      verifications: Map.unmodifiable({
        ...verifications,
        node.storageKey: verification,
      }),
    );
  }

  int? latencyFor(NodeInfo node) =>
      latencies[_latencyKey(node)] ?? latencies[node.addr];

  /// Address-keyed payload kept in sync for downgrade compatibility.
  Map<String, int> get legacyLatencies {
    final byAddress = <String, int>{};
    for (final entry in latencies.entries) {
      final separator = entry.key.indexOf('\u0000');
      final address = separator == -1
          ? entry.key
          : entry.key.substring(separator + 1);
      byAddress[address] = entry.value;
    }
    return byAddress;
  }

  NodeCatalogPreferences withLatency(NodeInfo node, int latencyMs) {
    return copyWith(
      latencies: Map.unmodifiable({...latencies, _latencyKey(node): latencyMs}),
    );
  }

  static String _latencyKey(NodeInfo node) =>
      '${node.nodeId}\u0000${node.addr}';
}
