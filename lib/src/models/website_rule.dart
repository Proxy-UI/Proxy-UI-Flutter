import 'upstream_endpoint.dart';

/// Where a website rule sends new connections.
sealed class RuleTarget {
  const RuleTarget();

  factory RuleTarget.fromJson(Map<dynamic, dynamic> json) =>
      switch (json['action']) {
        'direct' => const DirectTarget(),
        'node' => NodeTarget(
          json['node_id'] as String,
          UpstreamEndpoint(
            json['host'] as String,
            json['port'] as int,
            UpstreamTransport.values.byName(json['transport'] as String),
          ),
        ),
        final action => throw FormatException('Unknown rule action $action'),
      };

  /// The shape the native rule store and the local API share.
  Map<String, Object?> toJson();
}

final class DirectTarget extends RuleTarget {
  const DirectTarget();

  @override
  Map<String, Object?> toJson() => {'action': 'direct'};
}

/// A node and the endpoint pinned when the rule was saved.
final class NodeTarget extends RuleTarget {
  const NodeTarget(this.nodeId, this.endpoint);

  final String nodeId;
  final UpstreamEndpoint endpoint;

  @override
  Map<String, Object?> toJson() => {
    'action': 'node',
    'node_id': nodeId,
    'host': endpoint.host,
    'port': endpoint.port,
    'transport': endpoint.transport.name,
  };
}

/// One saved rule. [site] is the canonical form native code stores:
/// `[*.]host[:port]`, with an IPv6 host in brackets.
class WebsiteRule {
  const WebsiteRule(this.site, this.target);

  factory WebsiteRule.fromJson(Map<dynamic, dynamic> json) => WebsiteRule(
    json['site'] as String,
    RuleTarget.fromJson(json['target'] as Map),
  );

  static List<WebsiteRule> listFromJson(Map<dynamic, dynamic> json) => [
    for (final row in json['rules'] as List) WebsiteRule.fromJson(row as Map),
  ];

  final String site;
  final RuleTarget target;

  /// `*.example.com` covers every subdomain, not the domain itself.
  bool get coversSubdomains => site.startsWith('*.');

  static final _port = RegExp(r':(\d+)$');

  /// The only port the rule applies to, or null for every port.
  int? get port {
    // A bare IPv6 host never reaches here: canonical sites bracket it.
    final match = _port.firstMatch(site);
    return match == null ? null : int.parse(match[1]!);
  }

  /// The host without the wildcard or the port.
  String get host {
    var host = coversSubdomains ? site.substring(2) : site;
    final match = _port.firstMatch(host);
    if (match != null) host = host.substring(0, match.start);
    return host;
  }
}
