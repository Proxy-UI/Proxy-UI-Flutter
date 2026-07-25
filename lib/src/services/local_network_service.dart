import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

typedef WifiAddressLookup = Future<String?> Function();

class LocalNetworkService {
  LocalNetworkService({WifiAddressLookup? wifiAddressLookup})
    : _wifiAddressLookup = wifiAddressLookup ?? NetworkInfo().getWifiIP;

  final WifiAddressLookup _wifiAddressLookup;

  Future<String?> getWifiAddress() async {
    try {
      final value = (await _wifiAddressLookup())?.trim();
      if (value == null || value.isEmpty) return null;

      final address = InternetAddress.tryParse(value);
      if (address == null ||
          address.isLoopback ||
          address.address == InternetAddress.anyIPv4.address ||
          address.address == InternetAddress.anyIPv6.address) {
        return null;
      }
      return address.address;
    } catch (_) {
      return null;
    }
  }

  Future<String?> getHttpProxyUrl(int port) async {
    if (port < 1 || port > 65535) return null;
    final address = await getWifiAddress();
    if (address == null) return null;
    final host = address.contains(':') ? '[$address]' : address;
    return 'http://$host:$port';
  }
}
