import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A local address that other devices on the same network can reach.
@immutable
class LanAddress {
  const LanAddress({required this.address, required this.interfaceName});

  final String address;

  /// The adapter the address sits on, shown so a machine on several networks
  /// can be told apart: `WLAN` and `Ethernet` are both "the LAN" to this app,
  /// only one of them is the network the phone in your hand is on.
  final String interfaceName;

  bool get isIPv6 => address.contains(':');

  /// The host part of a URL. IPv6 literals have to be bracketed.
  String get urlHost => isIPv6 ? '[$address]' : address;

  String httpProxyUrl(int port) => 'http://$urlHost:$port';

  @override
  bool operator ==(Object other) =>
      other is LanAddress &&
      other.address == address &&
      other.interfaceName == interfaceName;

  @override
  int get hashCode => Object.hash(address, interfaceName);

  @override
  String toString() => '$address ($interfaceName)';
}

typedef NetworkInterfaceLookup = Future<List<NetworkInterface>> Function();

/// Finds the addresses this machine can be reached at from the local network.
///
/// Enumeration is `dart:io`'s, which is the same call on every platform. An
/// earlier version asked a plugin for the Wi-Fi address instead, which reported
/// nothing on a machine reached over Ethernet, and nothing on a Wi-Fi card that
/// presents more than one radio interface.
///
/// What the operating system cannot tell us through `dart:io` is which adapter
/// actually carries traffic, so the ordering here is a preference and not a
/// verdict: [listLanAddresses] returns every plausible address so the caller can
/// offer the rest when the first one is not the right network.
class LocalNetworkService {
  LocalNetworkService({NetworkInterfaceLookup? interfaceLookup})
    : _interfaceLookup = interfaceLookup ?? _listInterfaces;

  final NetworkInterfaceLookup _interfaceLookup;

  static const String _preferredAddressKey = 'lan_proxy_preferred_address';

  static Future<List<NetworkInterface>> _listInterfaces() =>
      NetworkInterface.list(
        // Link-local and loopback are dropped by `_isShareable` instead, so
        // every exclusion rule reads in one place and can be tested directly.
        includeLoopback: true,
        includeLinkLocal: true,
      );

  /// Adapters that carry traffic somewhere other than the local network.
  ///
  /// A tunnel normally owns the default route — this app installs one that
  /// does — so it would otherwise look like the best answer while being
  /// reachable by nobody.
  static const List<String> _tunnelMarkers = <String>[
    'tun',
    'tap',
    'utun',
    'ppp',
    'ipsec',
    'wg',
    'wireguard',
    'openvpn',
    'tailscale',
    'zerotier',
  ];

  /// Adapters that exist for virtual machines and containers. They are up and
  /// privately addressed, which is exactly why they have to be named: nothing
  /// outside the host is on them.
  static const List<String> _virtualMarkers = <String>[
    'vethernet',
    'veth',
    'hyper-v',
    'vmware',
    'virtualbox',
    'vboxnet',
    'docker',
    'br-',
    'bridge',
    'bluetooth',
    '蓝牙',
  ];

  /// Every address worth offering, best guess first.
  Future<List<LanAddress>> listLanAddresses() async {
    final List<NetworkInterface> interfaces;
    try {
      interfaces = await _interfaceLookup();
    } catch (error) {
      debugPrint('Failed to enumerate network interfaces: $error');
      return const <LanAddress>[];
    }

    final candidates = <(int, LanAddress)>[];
    for (final interface in interfaces) {
      if (_isExcludedInterface(interface.name)) continue;
      for (final address in interface.addresses) {
        if (!_isShareable(address)) continue;
        candidates.add((
          _rank(address),
          LanAddress(
            address: address.address,
            interfaceName: interface.name,
          ),
        ));
      }
    }

    candidates.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);
      if (byRank != 0) return byRank;
      final byInterface = a.$2.interfaceName.compareTo(b.$2.interfaceName);
      if (byInterface != 0) return byInterface;
      return a.$2.address.compareTo(b.$2.address);
    });

    // One address per adapter and family. Windows keeps several rotating IPv6
    // privacy addresses on a live adapter, and offering four spellings of the
    // same network as four choices only makes the real choice harder to see.
    final seen = <String>{};
    final addresses = <LanAddress>[];
    for (final candidate in candidates) {
      final address = candidate.$2;
      if (seen.add('${address.interfaceName}/${address.isIPv6}')) {
        addresses.add(address);
      }
    }
    return addresses;
  }

  /// The address to offer, honouring a choice the user made earlier.
  ///
  /// A remembered address that no longer exists — a network changed, a cable
  /// moved — falls back to the best guess rather than reporting nothing.
  Future<LanAddress?> resolveLanAddress({String? preferredAddress}) async {
    final addresses = await listLanAddresses();
    if (addresses.isEmpty) return null;
    if (preferredAddress == null) return addresses.first;
    for (final address in addresses) {
      if (address.address == preferredAddress) return address;
    }
    return addresses.first;
  }

  Future<String?> getHttpProxyUrl(int port, {String? preferredAddress}) async {
    if (port < 1 || port > 65535) return null;
    final address = await resolveLanAddress(preferredAddress: preferredAddress);
    return address?.httpProxyUrl(port);
  }

  /// The address the user last picked, or null when they never picked one.
  ///
  /// Time-boxed because the caller shows a spinner until it answers, and a
  /// remembered preference is not worth a card that spins forever if the store
  /// is slow to open or unavailable.
  Future<String?> loadPreferredAddress() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 2),
      );
      final stored = prefs.getString(_preferredAddressKey);
      return (stored == null || stored.isEmpty) ? null : stored;
    } catch (error) {
      debugPrint('Failed to read the preferred LAN address: $error');
      return null;
    }
  }

  Future<void> savePreferredAddress(String? address) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (address == null || address.isEmpty) {
        await prefs.remove(_preferredAddressKey);
      } else {
        await prefs.setString(_preferredAddressKey, address);
      }
    } catch (error) {
      debugPrint('Failed to store the preferred LAN address: $error');
    }
  }

  static bool _isExcludedInterface(String name) {
    final lower = name.toLowerCase();
    for (final marker in _tunnelMarkers) {
      if (lower.contains(marker)) return true;
    }
    for (final marker in _virtualMarkers) {
      if (lower.contains(marker)) return true;
    }
    return false;
  }

  /// Whether another device could open a connection to this address.
  static bool _isShareable(InternetAddress address) {
    if (address.isLoopback) return false;
    if (address.address == InternetAddress.anyIPv4.address) return false;
    if (address.address == InternetAddress.anyIPv6.address) return false;

    if (address.type == InternetAddressType.IPv4) {
      final octets = address.rawAddress;
      if (octets.length != 4) return false;
      // 169.254.0.0/16. Windows hands these out to adapters that never got a
      // lease, so they outnumber real addresses on a machine with several
      // disconnected adapters, and none of them reaches anything.
      if (octets[0] == 169 && octets[1] == 254) return false;
      return true;
    }

    if (address.type == InternetAddressType.IPv6) {
      final bytes = address.rawAddress;
      if (bytes.length != 16) return false;
      // fe80::/10, the IPv6 equivalent, unusable without a zone index.
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return false;
      return true;
    }

    return false;
  }

  /// Lower sorts earlier. Private IPv4 first, because that is what a phone on
  /// the same router will be able to reach.
  static int _rank(InternetAddress address) {
    if (address.type == InternetAddressType.IPv4) {
      final octets = address.rawAddress;
      if (octets[0] == 192 && octets[1] == 168) return 0;
      if (octets[0] == 10) return 1;
      if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return 2;
      return 3;
    }
    // fc00::/7, the IPv6 private range.
    final bytes = address.rawAddress;
    if ((bytes[0] & 0xfe) == 0xfc) return 4;
    return 5;
  }
}
