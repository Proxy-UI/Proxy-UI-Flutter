import 'dart:async';

import 'package:flutter/services.dart';

class AndroidVpnApplication {
  final String packageName;
  final String label;
  final bool isSystem;
  final Uint8List? iconPng;

  const AndroidVpnApplication({
    required this.packageName,
    required this.label,
    required this.isSystem,
    this.iconPng,
  });

  factory AndroidVpnApplication.fromPlatform(Map<Object?, Object?> value) {
    return AndroidVpnApplication(
      packageName: value['packageName'] as String? ?? '',
      label: value['label'] as String? ?? '',
      isSystem: value['system'] as bool? ?? false,
      iconPng: value['icon'] as Uint8List?,
    );
  }
}

class AndroidVpnInterface {
  final int fileDescriptor;
  final int mtu;
  final String diagnostics;

  const AndroidVpnInterface({
    required this.fileDescriptor,
    required this.mtu,
    required this.diagnostics,
  });
}

class AndroidVpnStateEvent {
  final bool running;
  final String? error;

  const AndroidVpnStateEvent({required this.running, this.error});
}

class AndroidVpnNetworkState {
  final bool validated;
  final String diagnostics;

  const AndroidVpnNetworkState({
    required this.validated,
    required this.diagnostics,
  });
}

class AndroidVpnService {
  AndroidVpnService._() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static final AndroidVpnService instance = AndroidVpnService._();

  static const MethodChannel _channel = MethodChannel(
    'com.proxyui.proxy_ui/vpn',
  );
  final StreamController<AndroidVpnStateEvent> _states =
      StreamController<AndroidVpnStateEvent>.broadcast();

  Stream<AndroidVpnStateEvent> get states => _states.stream;

  Future<List<AndroidVpnApplication>> listInstalledApps() async {
    final values = await _channel.invokeListMethod<Object?>(
      'listInstalledApps',
    );
    return values
            ?.whereType<Map<Object?, Object?>>()
            .map(AndroidVpnApplication.fromPlatform)
            .where((application) => application.packageName.isNotEmpty)
            .toList(growable: false) ??
        const [];
  }

  Future<AndroidVpnInterface> startInterface({
    required String mode,
    required List<String> packages,
    int mtu = 1500,
  }) async {
    final value = await _channel.invokeMapMethod<Object?, Object?>('startVpn', {
      'mode': mode,
      'packages': packages,
      'mtu': mtu,
    });
    final fd = value?['fd'] as int?;
    if (fd == null || fd < 0) {
      throw PlatformException(
        code: 'vpn_start_failed',
        message: 'Android returned no VPN file descriptor',
      );
    }
    return AndroidVpnInterface(
      fileDescriptor: fd,
      mtu: value?['mtu'] as int? ?? mtu,
      diagnostics: value?['diagnostics'] as String? ?? 'unavailable',
    );
  }

  Future<void> stopInterface() async {
    await _channel.invokeMethod<bool>('stopVpn');
  }

  Future<bool> get isRunning async =>
      await _channel.invokeMethod<bool>('getVpnState') ?? false;

  Future<AndroidVpnNetworkState> get networkState async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'getVpnNetworkState',
    );
    return AndroidVpnNetworkState(
      validated: value?['validated'] as bool? ?? false,
      diagnostics: value?['diagnostics'] as String? ?? 'unavailable',
    );
  }

  Future<AndroidVpnNetworkState> waitForValidation({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var state = await networkState;
    while (!state.validated && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      state = await networkState;
    }
    return state;
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'vpnStateChanged') return;
    final arguments = (call.arguments as Map<Object?, Object?>?) ?? const {};
    _states.add(
      AndroidVpnStateEvent(
        running: arguments['running'] as bool? ?? false,
        error: arguments['error'] as String?,
      ),
    );
  }
}
