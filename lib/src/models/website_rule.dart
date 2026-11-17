import 'upstream_endpoint.dart';

class WebsiteRule {
  const WebsiteRule(this.site, {this.nodeId, this.endpoint});
  final String site;
  final String? nodeId;
  final UpstreamEndpoint? endpoint;

  factory WebsiteRule.fromJson(Map row) {
    final site = row['site'] as String;
    final target = row['target'] as Map;
    if (target['action'] == 'direct') return WebsiteRule(site);
    return WebsiteRule(
      site,
      nodeId: target['node_id'] as String,
      endpoint: UpstreamEndpoint(
        target['host'] as String,
        target['port'] as int,
        UpstreamTransport.values.byName(target['transport'] as String),
      ),
    );
  }
}
