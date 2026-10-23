/// Whether a node serves QUIC, as it said when asked.
///
/// A node's QUIC listener is its own UDP port, which the catalogue does not
/// carry, so it is asked for separately. An answer that could not be had,
/// from an unreachable node or one older than the question, is [unknown]
/// rather than [none]: the node may well serve QUIC.
class QuicSupport {
  const QuicSupport.at(int this.port) : known = true;
  const QuicSupport._(this.known) : port = null;

  static const unknown = QuicSupport._(false);
  static const none = QuicSupport._(true);

  /// Whether the node answered the question at all.
  final bool known;

  /// The UDP port of its QUIC listener; null when it has none or is unknown.
  final int? port;

  bool get isAvailable => port != null;

  /// One entry of the native `quic_endpoints` answer.
  static QuicSupport fromJson(Object? value) {
    if (value is! Map) return unknown;
    if (value['available'] == true) {
      final port = value['port'];
      return port is int && port >= 1 && port <= 65535
          ? QuicSupport.at(port)
          : unknown;
    }
    return value['available'] == false && value['error'] == null
        ? none
        : unknown;
  }
}
