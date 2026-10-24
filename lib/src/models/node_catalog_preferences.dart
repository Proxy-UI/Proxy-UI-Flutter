import 'node_model.dart';
import 'upstream_endpoint.dart';

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

  /// Egress verifications over each node's own address, keyed by
  /// [NodeInfo.storageKey]: TCP, or QUIC for a `quic://` entry. Older builds
  /// read this map and nothing else.
  final Map<String, NodeVerification> verifications;

  /// Verifications over the QUIC endpoint a TCP entry reported, kept apart
  /// so the two carriers' latencies can be compared rather than one
  /// replacing the other.
  final Map<String, NodeVerification> quicVerifications;

  /// The carrier the node map tests and connects over where a node serves
  /// both; null until the user picks one.
  final UpstreamTransport? carrier;

  const NodeCatalogPreferences({
    this.serverHost = '',
    this.serverPort = 1081,
    this.sessionKey,
    this.sortByLatency = false,
    this.latencies = const {},
    this.nodes = const [],
    this.fetchedAt,
    this.verifications = const {},
    this.quicVerifications = const {},
    this.carrier,
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

    Map<String, NodeVerification> verificationsAt(String field) {
      final verifications = <String, NodeVerification>{};
      final raw = json[field];
      if (raw is Map) {
        for (final entry in raw.entries) {
          final key = entry.key;
          final verification = NodeVerification.fromJson(entry.value);
          if (key is String && verification != null) {
            verifications[key] = verification;
          }
        }
      }
      return verifications;
    }

    final verifications = verificationsAt('verifications');
    final quicVerifications = verificationsAt('quicVerifications');
    // The build before the second slot kept one result per node, and a QUIC
    // test of a TCP entry replaced its TCP result there, latency included.
    // A `quic://` entry's results are its own whatever they say: builds
    // older still recorded no carrier, which reads as TCP.
    for (final key in [...verifications.keys]) {
      final verification = verifications[key]!;
      final address = key.substring(key.indexOf('\u0000') + 1);
      final own =
          UpstreamEndpoint.tryParse(address)?.transport ??
          UpstreamTransport.tcp;
      if (verification.carrier == UpstreamTransport.quic &&
          own == UpstreamTransport.tcp) {
        verifications.remove(key);
        latencies.remove(key);
        quicVerifications.putIfAbsent(key, () => verification);
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
      fetchedAt: DateTime.tryParse(json['fetchedAt']?.toString() ?? '')
          ?.toLocal(),
      verifications: Map.unmodifiable(verifications),
      quicVerifications: Map.unmodifiable(quicVerifications),
      carrier: UpstreamTransport.values
          .where((carrier) => carrier.name == json['carrier'])
          .firstOrNull,
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
      for (final entry in verifications.entries)
        entry.key: entry.value.toJson(),
    },
    'quicVerifications': {
      for (final entry in quicVerifications.entries)
        entry.key: entry.value.toJson(),
    },
    'carrier': carrier?.name,
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
    Map<String, NodeVerification>? quicVerifications,
    UpstreamTransport? carrier,
  }) => NodeCatalogPreferences(
    serverHost: serverHost ?? this.serverHost,
    serverPort: serverPort ?? this.serverPort,
    sessionKey: sessionKey ?? this.sessionKey,
    sortByLatency: sortByLatency ?? this.sortByLatency,
    latencies: latencies ?? this.latencies,
    nodes: nodes ?? this.nodes,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    verifications: verifications ?? this.verifications,
    quicVerifications: quicVerifications ?? this.quicVerifications,
    carrier: carrier ?? this.carrier,
  );

  /// Replaces the cached catalogue, dropping verifications for nodes the server
  /// no longer lists so the store cannot grow without bound.
  NodeCatalogPreferences withCatalog(List<NodeInfo> catalog, DateTime at) {
    final live = catalog.map((node) => node.storageKey).toSet();
    Map<String, NodeVerification> listed(Map<String, NodeVerification> all) =>
        Map.unmodifiable({
          for (final entry in all.entries)
            if (live.contains(entry.key)) entry.key: entry.value,
        });
    return copyWith(
      nodes: List.unmodifiable(catalog),
      fetchedAt: at,
      verifications: listed(verifications),
      quicVerifications: listed(quicVerifications),
    );
  }

  /// [node]'s last result over [carrier], by default its own address's.
  /// A `quic://` entry has no TCP address, so nothing over TCP.
  NodeVerification? verificationFor(
    NodeInfo node, [
    UpstreamTransport? carrier,
  ]) {
    carrier ??= node.carrier;
    if (carrier == node.carrier) return verifications[node.storageKey];
    return carrier == UpstreamTransport.quic
        ? quicVerifications[node.storageKey]
        : null;
  }

  /// Records how each node in [results] answered, each under the carrier
  /// that carried it, copying the stores once for the whole batch.
  ///
  /// A failed test leaves a node's previous latency alone rather than
  /// replacing it with a number that measured nothing.
  NodeCatalogPreferences withResults(
    Iterable<(NodeInfo, NodeVerification)> results,
  ) {
    final verifications = {...this.verifications};
    final quicVerifications = {...this.quicVerifications};
    final latencies = {...this.latencies};
    for (final (node, verification) in results) {
      if (verification.carrier == UpstreamTransport.quic &&
          node.carrier == UpstreamTransport.tcp) {
        quicVerifications[node.storageKey] = verification;
        continue;
      }
      verifications[node.storageKey] = verification;
      final latency = verification.latencyMs;
      if (verification.isVerified && latency != null) {
        latencies[_latencyKey(node)] = latency;
      }
    }
    return copyWith(
      verifications: Map.unmodifiable(verifications),
      quicVerifications: Map.unmodifiable(quicVerifications),
      latencies: Map.unmodifiable(latencies),
    );
  }

  /// The latency last measured over [node]'s own address.
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

  static String _latencyKey(NodeInfo node) =>
      '${node.nodeId}\u0000${node.addr}';
}
