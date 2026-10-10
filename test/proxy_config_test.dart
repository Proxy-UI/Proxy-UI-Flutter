import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/proxy_config.dart';

void main() {
  test('TUN resolver persists across imports and copies', () {
    expect(ProxyConfigModel.fromJson({}).tunDnsServer, '8.8.8.8');
    final config = ProxyConfigModel.fromJson({'tunDnsServer': ' 10.20.30.53 '});
    expect(config.tunDnsServer, '10.20.30.53');
    expect(
      ProxyConfigModel.fromJson(config.toJson()).tunDnsServer,
      '10.20.30.53',
    );
    expect(
      config.copyWith(serverHost: 'other.test').tunDnsServer,
      '10.20.30.53',
    );
    expect(config.copyWith(tunDnsServer: '::1').tunDnsServer, '::1');
  });
  group('ProxyConfigModel', () {
    test('Fake-IP is opt-in for fresh and upgraded configurations', () {
      expect(ProxyConfigModel().tunFakeIp, isFalse);
      expect(ProxyConfigModel.fromJson({}).tunFakeIp, isFalse);
      final enabled = ProxyConfigModel.fromJson({'tunFakeIp': 'true'});
      expect(enabled.tunFakeIp, isTrue);
      expect(ProxyConfigModel.fromJson(enabled.toJson()).tunFakeIp, isTrue);
      expect(enabled.copyWith(serverHost: 'other.test').tunFakeIp, isTrue);
      expect(enabled.copyWith(tunFakeIp: false).tunFakeIp, isFalse);
    });
    test('protocol migration preserves legacy and explicit v2 selections', () {
      expect(ProxyConfigModel().secureTransport, isFalse);
      expect(ProxyConfigModel.fromJson({}).secureTransport, isFalse);
      final secure = ProxyConfigModel(secureTransport: true);
      expect(
        ProxyConfigModel.fromJson(secure.toJson()).secureTransport,
        isTrue,
      );
      expect(
        secure.copyWith(serverHost: 'new.example').secureTransport,
        isTrue,
      );
    });
    // New installs moved off 1080, which too many other proxy tools claim.
    // Imported configurations still fall back to 1080, covered below.
    test('uses 10801 as default local port', () {
      final config = ProxyConfigModel();
      expect(config.localPort, 10801);
    });

    test('fromJson falls back for invalid port values', () {
      final config = ProxyConfigModel.fromJson({
        'serverHost': 'example.com',
        'serverPort': -1,
        'localPort': 'invalid',
      });

      expect(config.serverPort, 1081);
      expect(config.localPort, 1080);
    });

    test('fromJson parses boolean strings', () {
      final config = ProxyConfigModel.fromJson({
        'autoProxy': 'false',
        'reverseGeo': 'true',
        'forceCodec': 'true',
      });

      expect(config.autoProxy, isFalse);
      expect(config.reverseGeo, isTrue);
      expect(config.forceCodec, isTrue);
    });
  });
}
