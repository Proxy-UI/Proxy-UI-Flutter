import 'dart:io';

/// Measures the TCP handshake time to a node without changing proxy state.
Future<int> measureNodeTcpLatency({
  required String host,
  required int port,
  Duration timeout = const Duration(seconds: 5),
}) async {
  Socket? socket;
  final stopwatch = Stopwatch()..start();
  try {
    socket = await Socket.connect(host, port, timeout: timeout);
    stopwatch.stop();
    return stopwatch.elapsedMilliseconds.clamp(1, 1 << 31).toInt();
  } finally {
    socket?.destroy();
  }
}
