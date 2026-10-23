import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/node_model.dart';

void main() {
  group('NodeInfo', () {
    test('QUIC node selection preserves the carrier through configuration', () {
      final node = NodeInfo(
        nodeId: 'quic',
        addr: 'quic://[::1]:10811',
        lastSeen: DateTime.now(),
        country: '',
        region: '',
      );
      expect(node.host, 'quic://[::1]');
      expect(node.port, 10811);
      expect(node.toProxyConfig().serverHost, 'quic://[::1]');
    });
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
      expect(node.toProxyConfig().tunFakeIp, isFalse);
      expect(node.toProxyConfig(tunFakeIp: true).tunFakeIp, isTrue);
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
