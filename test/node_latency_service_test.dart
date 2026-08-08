import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/node_latency_service.dart';

void main() {
  test('measures a loopback TCP handshake without proxy state', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((socket) => socket.destroy());
    try {
      final latency = await measureNodeTcpLatency(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
      );

      expect(latency, greaterThanOrEqualTo(1));
    } finally {
      await subscription.cancel();
      await server.close();
    }
  });
}
