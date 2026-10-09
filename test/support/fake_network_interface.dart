import 'dart:io';
import 'dart:typed_data';

class FakeNetworkInterface implements NetworkInterface {
  FakeNetworkInterface(this.name, List<String> addresses)
    : addresses = addresses.map(_FakeInterfaceAddress.new).toList();

  @override
  final String name;
  @override
  final List<InterfaceAddress> addresses;
  @override
  int get index => 0;
}

class _FakeInterfaceAddress implements InterfaceAddress {
  _FakeInterfaceAddress(String address) : _address = InternetAddress(address);
  final InternetAddress _address;

  @override
  String get address => _address.address;
  @override
  String get host => _address.host;
  @override
  InternetAddressType get type => _address.type;
  @override
  Uint8List get rawAddress => _address.rawAddress;
  @override
  bool get isLoopback => _address.isLoopback;
  @override
  bool get isLinkLocal => _address.isLinkLocal;
  @override
  bool get isMulticast => _address.isMulticast;
  @override
  Future<InternetAddress> reverse() => _address.reverse();
  @override
  int get prefixLength => type == InternetAddressType.IPv4 ? 24 : 64;
  @override
  InternetAddress? get broadcast => null;
}
