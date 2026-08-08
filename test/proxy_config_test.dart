import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/proxy_config.dart';

void main() {
  group('ProxyConfigModel', () {
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
