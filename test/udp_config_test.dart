import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/proxy_config.dart';
import 'package:proxy_ui/src/services/clash_config_generator.dart';
import 'package:proxy_ui/src/services/shadowrocket_config_generator.dart';

void main() {
  test('legacy config imports with UDP enabled', () {
    final config = ProxyConfigModel.fromJson({
      'serverHost': 'proxy.example.com',
      'localPort': 1080,
    });

    expect(config.udpEnabled, isTrue);
    expect(config.tunEnabled, isFalse);
    expect(config.tunBypassProcesses, isEmpty);
    expect(config.toJson()['udpEnabled'], isTrue);
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

  test('generated client subscriptions follow the UDP setting', () {
    final enabled = ProxyConfigModel(
      serverHost: 'proxy.example.com',
      localPort: 1080,
      udpEnabled: true,
    );
    final disabled = enabled.copyWith(udpEnabled: false);

    expect(ClashConfigGenerator.generate(enabled), contains('udp: true'));
    expect(ClashConfigGenerator.generate(disabled), contains('udp: false'));
    expect(ShadowrocketConfigGenerator.generate(enabled), contains('udp=1'));
    expect(ShadowrocketConfigGenerator.generate(disabled), contains('udp=0'));
  });
}
