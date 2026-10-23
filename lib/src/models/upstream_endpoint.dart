/// [UpstreamEndpoint.label] for a configured host and port, or the two as they
/// are when they do not parse.
String endpointLabel(String host, int port) =>
    UpstreamEndpoint.tryFromHost(host, port)?.label ?? '$host:$port';

/// Native carrier selection. Destination TCP/UDP is independent of this choice.
enum UpstreamTransport {
  tcp,
  quic;

  /// The protocol's own name, which needs no translation.
  String get label => switch (this) {
    UpstreamTransport.tcp => 'TCP',
    UpstreamTransport.quic => 'QUIC',
  };
}

class UpstreamEndpoint {
  final String host;
  final int port;
  final UpstreamTransport transport;

  const UpstreamEndpoint(this.host, this.port, this.transport);

  factory UpstreamEndpoint.fromHost(String value, int port) {
    value = value.trim();
    var transport = UpstreamTransport.tcp;
    if (value.contains('://')) {
      // Uri would percent-encode a space into the host instead of failing.
      if (value.contains(RegExp(r'\s'))) {
        throw const FormatException('Invalid native proxy endpoint');
      }
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

  static UpstreamEndpoint? tryParse(String value) {
    try {
      return UpstreamEndpoint.parse(value);
    } on FormatException {
      return null;
    }
  }

  static UpstreamEndpoint? tryFromHost(String value, int port) {
    try {
      return UpstreamEndpoint.fromHost(value, port);
    } on FormatException {
      return null;
    }
  }

  /// What a pasted server field carries besides its host: a carrier from
  /// `quic://` or `tcp://`, and a port. Null when [value] is a bare host, so
  /// typing is left alone, or when it does not parse.
  static ({String host, int? port, UpstreamTransport? transport})? splitInput(
    String value,
  ) {
    value = value.trim();
    if (value.contains('://')) {
      final uri = Uri.tryParse(value);
      final endpoint = tryFromHost(value, 1);
      if (uri == null || endpoint == null) return null;
      return (
        host: endpoint.host,
        port: uri.hasPort ? endpoint.port : null,
        transport: endpoint.transport,
      );
    }
    // `[v6]:port` or `name:port`. A bare IPv6 address has several colons
    // and no brackets, and stays a host.
    final bracketed = RegExp(r'^\[([^\]]+)\]:(\d+)$').firstMatch(value);
    final named = RegExp(r'^([^:\[\]]+):(\d+)$').firstMatch(value);
    final match = bracketed ?? named;
    final port = int.tryParse(match?[2] ?? '');
    if (match == null || port == null) return null;
    final endpoint = tryFromHost(match[1]!, port);
    if (endpoint == null) return null;
    return (host: endpoint.host, port: endpoint.port, transport: null);
  }

  bool get isQuic => transport == UpstreamTransport.quic;

  /// `host:port` without the carrier, as people read and type it.
  String get address => '${host.contains(':') ? '[$host]' : host}:$port';

  /// [address], naming the carrier only when it is not the TCP default.
  String get label => isQuic ? '$address · ${transport.label}' : address;

  String get qualifiedHost => transport == UpstreamTransport.tcp
      ? host
      : 'quic://${host.contains(':') ? '[$host]' : host}';
}
