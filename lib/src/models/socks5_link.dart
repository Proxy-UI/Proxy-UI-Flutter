/// How a standard SOCKS5 client connects to a node, as the node reports it.
///
/// Nodes only report one while their administrator has the SOCKS5 endpoint
/// enabled; it is managed with `http-proxy-admin`, never from the app.
class Socks5Link {
  const Socks5Link({
    required this.url,
    required this.username,
    required this.host,
    required this.port,
    required this.udp,
  });

  /// `socks5://user:password@host:port`, ready to paste into a client.
  final String url;
  final String username;
  final String host;
  final int port;

  /// Whether the endpoint also relays UDP.
  final bool udp;

  /// `host:port`, shown in place of the link until its credentials are
  /// asked for: the part that fits beside a node and is checked at a glance.
  String get address => '${host.contains(':') ? '[$host]' : host}:$port';

  /// Null when the node serves no SOCKS5 endpoint or the answer is malformed.
  static Socks5Link? fromJson(Map<String, dynamic> json) {
    if (json['available'] != true) return null;
    final url = json['url'];
    final username = json['username'];
    final host = json['host'];
    final port = json['port'];
    if (url is! String ||
        !url.startsWith('socks5://') ||
        username is! String ||
        host is! String ||
        port is! int) {
      return null;
    }
    return Socks5Link(
      url: url,
      username: username,
      host: host,
      port: port,
      udp: json['udp'] == true,
    );
  }
}
