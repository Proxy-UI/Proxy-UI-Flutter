import 'dart:io';

import 'support/fake_network_interface.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/local_network_service.dart';

/// A stand-in for a real adapter. `NetworkInterface` cannot be built directly,
/// and the machine running the tests is not the machine being described.

LocalNetworkService serviceWith(List<NetworkInterface> interfaces) =>
    LocalNetworkService(interfaceLookup: () async => interfaces);

void main() {
  test('builds a shareable HTTP proxy URL from a LAN address', () async {
    final service = serviceWith([
      FakeNetworkInterface('WLAN', ['192.168.21.33']),
    ]);

    expect(await service.getHttpProxyUrl(1080), 'http://192.168.21.33:1080');
  });

  test('brackets IPv6 addresses in HTTP proxy URLs', () async {
    final service = serviceWith([
      FakeNetworkInterface('eth0', ['fd00::1234']),
    ]);

    expect(await service.getHttpProxyUrl(8080), 'http://[fd00::1234]:8080');
  });

  test('rejects loopback, empty results, and invalid ports', () async {
    final loopback = serviceWith([
      FakeNetworkInterface('lo', ['127.0.0.1']),
    ]);
    final none = serviceWith([]);

    expect(await loopback.getHttpProxyUrl(1080), isNull);
    expect(await none.getHttpProxyUrl(1080), isNull);
    expect(await none.getHttpProxyUrl(0), isNull);
    expect(
      await serviceWith([
        FakeNetworkInterface('WLAN', ['192.168.21.33']),
      ]).getHttpProxyUrl(65536),
      isNull,
    );
  });

  test('finds an Ethernet address, which a Wi-Fi lookup never reported', () {
    // The bug this replaced: a machine on a cable showed nothing at all.
    final service = serviceWith([
      FakeNetworkInterface('以太网', ['192.168.1.20']),
    ]);

    expect(
      service.getHttpProxyUrl(1080),
      completion('http://192.168.1.20:1080'),
    );
  });

  test('skips the addresses no other device can reach', () async {
    // Every one of these is present on a Windows machine running this app with
    // TUN on, and picking any of them hands out an address that reaches nobody.
    final service = serviceWith([
      FakeNetworkInterface('wintun', ['10.0.0.33']),
      FakeNetworkInterface('vEthernet (WSL)', ['172.30.0.1']),
      FakeNetworkInterface('vEthernet (Default Switch)', ['172.25.208.1']),
      FakeNetworkInterface('WLAN 3', ['169.254.176.13']),
      FakeNetworkInterface('蓝牙网络连接', ['169.254.82.119']),
      FakeNetworkInterface('Loopback Pseudo-Interface 1', ['127.0.0.1']),
      FakeNetworkInterface('WLAN', ['192.168.21.5']),
    ]);

    final addresses = await service.listLanAddresses();

    expect(addresses.map((a) => a.address), ['192.168.21.5']);
  });

  test('excludes third-party tunnels, not just our own', () async {
    final service = serviceWith([
      FakeNetworkInterface('utun4', ['10.2.0.2']),
      FakeNetworkInterface('tailscale0', ['100.64.1.2']),
      FakeNetworkInterface('wg0', ['10.7.0.2']),
      FakeNetworkInterface('en0', ['192.168.5.9']),
    ]);

    final addresses = await service.listLanAddresses();

    expect(addresses.map((a) => a.address), ['192.168.5.9']);
  });

  test('offers every usable address, home ranges first', () async {
    final service = serviceWith([
      FakeNetworkInterface('eth1', ['fd00::9']),
      FakeNetworkInterface('eth2', ['10.5.0.4']),
      FakeNetworkInterface('eth3', ['172.16.3.4']),
      FakeNetworkInterface('WLAN', ['192.168.1.7']),
    ]);

    final addresses = await service.listLanAddresses();

    expect(addresses.map((a) => a.address), [
      '192.168.1.7',
      '10.5.0.4',
      '172.16.3.4',
      'fd00::9',
    ]);
  });

  test('collapses the rotating IPv6 addresses of one adapter', () async {
    // Windows keeps several privacy addresses on a live adapter at once; a
    // real machine running this app offered four for a single Wi-Fi card.
    final service = serviceWith([
      FakeNetworkInterface('WLAN', [
        '192.168.21.5',
        '2408:8256:3102:5c70:35f3:6d9e:bbde:e508',
        '2408:8256:3102:5c70:755c:80f6:5a3d:6551',
        '2408:8256:3102:5c70:7cfb:3a74:e221:e16f',
      ]),
    ]);

    final addresses = await service.listLanAddresses();

    expect(addresses.map((a) => a.address), [
      '192.168.21.5',
      '2408:8256:3102:5c70:35f3:6d9e:bbde:e508',
    ]);
  });

  test(
    'honours a chosen address and names the adapter it belongs to',
    () async {
      // Two live networks is exactly when the first guess can be wrong, so the
      // choice has to survive being made.
      final service = serviceWith([
        FakeNetworkInterface('WLAN', ['192.168.21.5']),
        FakeNetworkInterface('以太网 2', ['192.168.255.10']),
      ]);

      final chosen = await service.resolveLanAddress(
        preferredAddress: '192.168.255.10',
      );

      expect(chosen?.address, '192.168.255.10');
      expect(chosen?.interfaceName, '以太网 2');
      expect(
        await service.getHttpProxyUrl(1080, preferredAddress: '192.168.255.10'),
        'http://192.168.255.10:1080',
      );
    },
  );

  test('falls back when a remembered address is gone', () async {
    final service = serviceWith([
      FakeNetworkInterface('WLAN', ['192.168.21.5']),
    ]);

    final chosen = await service.resolveLanAddress(
      preferredAddress: '192.168.255.10',
    );

    expect(chosen?.address, '192.168.21.5');
  });

  test('survives an enumeration failure instead of throwing', () async {
    final service = LocalNetworkService(
      interfaceLookup: () async => throw const SocketException('denied'),
    );

    expect(await service.listLanAddresses(), isEmpty);
    expect(await service.getHttpProxyUrl(1080), isNull);
  });
}
