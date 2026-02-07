import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/node_model.dart';

void main() {
  group('NodeInfo', () {
    test('parses IPv4 host and port', () {
      final node = NodeInfo(
        nodeId: 'n1',
        addr: '192.168.1.10:1081',
        lastSeen: DateTime.now(),
        country: 'US',
        region: 'CA',
      );

      expect(node.host, '192.168.1.10');
      expect(node.port, 1081);
    });

    test('parses bracketed IPv6 host and port', () {
      final node = NodeInfo(
        nodeId: 'n2',
        addr: '[2001:db8::1]:443',
        lastSeen: DateTime.now(),
        country: 'US',
        region: 'NY',
      );

      expect(node.host, '2001:db8::1');
      expect(node.port, 443);
    });

    test('throws on invalid address', () {
      final node = NodeInfo(
        nodeId: 'n3',
        addr: 'invalid-address',
        lastSeen: DateTime.now(),
        country: 'US',
        region: 'TX',
      );

      expect(() => node.host, throwsFormatException);
      expect(() => node.port, throwsFormatException);
    });
  });
}
