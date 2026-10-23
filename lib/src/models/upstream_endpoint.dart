/// Native carrier selection. Destination TCP/UDP is independent of this choice.
enum UpstreamTransport { tcp, quic }

class UpstreamEndpoint {
  final String host;
  final int port;
  final UpstreamTransport transport;

  const UpstreamEndpoint(this.host, this.port, this.transport);

  factory UpstreamEndpoint.fromHost(String value, int port) {
    value = value.trim();
    var transport = UpstreamTransport.tcp;
    if (value.contains('://')) {
      final uri = Uri.parse(value);
      if (!['tcp', 'quic'].contains(uri.scheme) ||
          uri.userInfo.isNotEmpty ||
          !['', '/'].contains(uri.path) ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException('Invalid native proxy endpoint');
      }
      transport = uri.scheme == 'quic'
          ? UpstreamTransport.quic
          : UpstreamTransport.tcp;
      value = uri.host;
      if (uri.hasPort) port = uri.port;
    }
    if (value.startsWith('[') && value.endsWith(']')) {
      value = value.substring(1, value.length - 1);
    }
    if (value.isEmpty ||
        value.contains(RegExp(r'[\s/@?#]')) ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('Invalid native proxy endpoint');
    }
    return UpstreamEndpoint(value, port, transport);
  }

  factory UpstreamEndpoint.parse(String value) {
    if (value.contains('://')) return UpstreamEndpoint.fromHost(value, 0);
    final separator = value.lastIndexOf(':');
    if (separator < 1) throw const FormatException('Missing proxy port');
    return UpstreamEndpoint.fromHost(
      value.substring(0, separator),
      int.parse(value.substring(separator + 1)),
    );
  }

  String get qualifiedHost => transport == UpstreamTransport.tcp
      ? host
      : 'quic://${host.contains(':') ? '[$host]' : host}';
}
