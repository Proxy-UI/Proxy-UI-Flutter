import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/proxy_config.dart';

void main() {
  test('new configurations keep UDP disabled by default', () {
    final config = ProxyConfigModel();

    expect(config.udpEnabled, isFalse);
    expect(config.udpDirectFallback, isTrue);
    expect(config.allowLan, isFalse);
    expect(config.toJson()['udpEnabled'], isFalse);
    expect(config.toJson()['udpDirectFallback'], isTrue);
    expect(config.toJson()['allowLan'], isFalse);
  });

  test('legacy imports leave UDP proxying disabled', () {
    final config = ProxyConfigModel.fromJson({
      'serverHost': 'proxy.example.com',
      'localPort': 1080,
    });

    expect(config.udpEnabled, isFalse);
    expect(config.udpDirectFallback, isTrue);
    expect(config.tunEnabled, isFalse);
    expect(config.tunBypassProcesses, isEmpty);
    expect(config.allowLan, isFalse);
    expect(config.toJson()['udpEnabled'], isFalse);
  });

  test('explicit UDP opt-in survives Auto configuration and persistence', () {
    final config = ProxyConfigModel(
      autoProxy: true,
      reverseGeo: true,
      udpEnabled: true,
    );
    final restored = ProxyConfigModel.fromJson(config.toJson());
    expect(restored.udpEnabled, isTrue);
    expect(restored.copyWith(autoProxy: false).udpEnabled, isTrue);
    expect(restored.copyWith(udpEnabled: false).autoProxy, isTrue);
  });

  test('LAN exposure is opt-in and survives persistence and copyWith', () {
    final config = ProxyConfigModel.fromJson({
      'serverHost': 'proxy.example.com',
      'allowLan': true,
    });

    expect(config.allowLan, isTrue);
    expect(config.toJson()['allowLan'], isTrue);
    expect(config.copyWith(serverPort: 8443).allowLan, isTrue);
    expect(config.copyWith(allowLan: false).allowLan, isFalse);
  });

  test('strict TUN UDP blocking round-trips and survives copyWith', () {
    final config = ProxyConfigModel.fromJson({
      'udpEnabled': false,
      'udpDirectFallback': false,
    });

    expect(config.udpDirectFallback, isFalse);
    expect(config.toJson()['udpDirectFallback'], isFalse);
    expect(config.copyWith(serverPort: 8443).udpDirectFallback, isFalse);
  });

  test('TUN process names are normalized and preserved by copyWith', () {
    final config = ProxyConfigModel(
      tunEnabled: true,
      tunBypassProcesses: const [' Browser.EXE ', 'browser', 'curl.exe'],
    );

    expect(config.tunBypassProcesses, ['browser', 'curl']);
    expect(config.toJson()['tunEnabled'], isTrue);
    expect(
      config
          .copyWith(tunBypassProcesses: const ['Downloader.EXE'])
          .tunBypassProcesses,
      ['downloader'],
    );
  });

  test(
    'Android VPN application policy round-trips and normalizes packages',
    () {
      final config = ProxyConfigModel.fromJson({
        'androidVpnRoutingMode': 'exclude',
        'androidVpnPackages': [
          ' com.example.browser ',
          'com.example.browser',
          'com.example.game',
        ],
      });

      expect(config.androidVpnRoutingMode, AndroidVpnRoutingMode.exclude);
      expect(config.androidVpnPackages, [
        'com.example.browser',
        'com.example.game',
      ]);
      expect(config.toJson()['androidVpnRoutingMode'], 'exclude');
      expect(
        config.copyWith(androidVpnRoutingMode: AndroidVpnRoutingMode.include),
        isA<ProxyConfigModel>().having(
          (value) => value.androidVpnRoutingMode,
          'routing mode',
          AndroidVpnRoutingMode.include,
        ),
      );
    },
  );
}
