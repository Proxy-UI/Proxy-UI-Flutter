import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/local_network_service.dart';

void main() {
  test('builds a shareable HTTP proxy URL from the Wi-Fi address', () async {
    final service = LocalNetworkService(
      wifiAddressLookup: () async => '192.168.21.33',
    );

    expect(await service.getHttpProxyUrl(1080), 'http://192.168.21.33:1080');
  });

  test('brackets IPv6 addresses in HTTP proxy URLs', () async {
    final service = LocalNetworkService(
      wifiAddressLookup: () async => 'fd00::1234',
    );

    expect(await service.getHttpProxyUrl(8080), 'http://[fd00::1234]:8080');
  });

  test('rejects loopback, missing addresses, and invalid ports', () async {
    final loopback = LocalNetworkService(
      wifiAddressLookup: () async => '127.0.0.1',
    );
    final missing = LocalNetworkService(wifiAddressLookup: () async => null);

    expect(await loopback.getHttpProxyUrl(1080), isNull);
    expect(await missing.getHttpProxyUrl(1080), isNull);
    expect(await missing.getHttpProxyUrl(0), isNull);
    expect(await missing.getHttpProxyUrl(65536), isNull);
  });
}
