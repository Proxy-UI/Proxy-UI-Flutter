import 'node_model.dart';

/// How a node answered its last test, as one word the whole UI agrees on.
///
/// The galaxy colours planets by it, the list shows it as a chip, and the
/// filters select by it, so the thresholds live here and nowhere else.
enum NodeHealth {
  /// A probe is in flight.
  testing,

  /// Answered within [fastLatencyMs].
  fast,

  /// Answered within [fairLatencyMs].
  fair,

  /// Answered, slowly.
  slow,

  /// The last probe failed.
  unreachable,

  /// Never tested.
  untested;

  /// A probe carries a full HTTPS request through the node, so these are
  /// higher than a ping would suggest.
  static const int fastLatencyMs = 250;
  static const int fairLatencyMs = 600;

  /// Whether traffic can be expected to flow.
  bool get isAvailable => this == fast || this == fair || this == slow;

  /// Order used when counting a country's nodes: healthy first.
  static const List<NodeHealth> displayOrder = [
    fast,
    fair,
    slow,
    testing,
    untested,
    unreachable,
  ];

  static NodeHealth fromLatency(int latencyMs) {
    if (latencyMs < fastLatencyMs) return fast;
    if (latencyMs < fairLatencyMs) return fair;
    return slow;
  }
}

/// The health of a node from what is known about it.
///
/// A recorded verification wins. Without one, a latency remembered from an
/// earlier build still says the node once answered.
NodeHealth nodeHealthOf({
  required bool testing,
  NodeVerification? verification,
  int? latencyMs,
}) {
  if (testing) return NodeHealth.testing;
  if (verification != null) {
    if (!verification.isVerified) return NodeHealth.unreachable;
    final latency = verification.latencyMs ?? latencyMs;
    return latency == null ? NodeHealth.fair : NodeHealth.fromLatency(latency);
  }
  if (latencyMs != null) return NodeHealth.fromLatency(latencyMs);
  return NodeHealth.untested;
}

/// Which nodes a health filter keeps.
enum NodeHealthFilter {
  all,
  available,
  unreachable,
  untested;

  bool keeps(NodeHealth health) => switch (this) {
    NodeHealthFilter.all => true,
    NodeHealthFilter.available => health.isAvailable,
    NodeHealthFilter.unreachable => health == NodeHealth.unreachable,
    NodeHealthFilter.untested =>
      health == NodeHealth.untested || health == NodeHealth.testing,
  };
}
