import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
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
  AndroidVpnService._(this._channel) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static final AndroidVpnService instance = AndroidVpnService._(
    _defaultChannel,
  );

  @visibleForTesting
  AndroidVpnService.forTesting(MethodChannel channel) : this._(channel);

  static const MethodChannel _defaultChannel = MethodChannel(
    'com.proxyui.proxy_ui/vpn',
  );
  static const int _maxCachedIcons = 128;
  static const int _maxIconBatchSize = 24;

  final MethodChannel _channel;
  final StreamController<AndroidVpnStateEvent> _states =
      StreamController<AndroidVpnStateEvent>.broadcast();
  final LinkedHashMap<String, Uint8List?> _iconCache = LinkedHashMap();
  final LinkedHashSet<String> _queuedIcons = LinkedHashSet();
  final Map<String, Completer<Uint8List?>> _pendingIcons = {};
  List<AndroidVpnApplication>? _applicationCache;
  Future<List<AndroidVpnApplication>>? _applicationRequest;
  Timer? _iconBatchTimer;

  Stream<AndroidVpnStateEvent> get states => _states.stream;

  Future<List<AndroidVpnApplication>> listInstalledApps({
    bool forceRefresh = false,
  }) {
    final cached = _applicationCache;
    if (!forceRefresh && cached != null) {
      return Future.value(cached);
    }
    final pendingRequest = _applicationRequest;
    if (!forceRefresh && pendingRequest != null) {
      return pendingRequest;
    }
    if (forceRefresh) {
      _applicationCache = null;
      _iconCache.clear();
    }

    final request = _fetchInstalledApps(forceRefresh: forceRefresh);
    _applicationRequest = request;
    void clearRequest() {
      if (identical(_applicationRequest, request)) _applicationRequest = null;
    }

    unawaited(
      request.then<void>(
        (_) => clearRequest(),
        onError: (_, _) => clearRequest(),
      ),
    );
    return request;
  }

  Future<List<AndroidVpnApplication>> _fetchInstalledApps({
    required bool forceRefresh,
  }) async {
    final values = await _channel.invokeListMethod<Object?>(
      'listInstalledApps',
      {'forceRefresh': forceRefresh},
    );
    final applications =
        values
            ?.whereType<Map<Object?, Object?>>()
            .map(AndroidVpnApplication.fromPlatform)
            .where((application) => application.packageName.isNotEmpty)
            .toList(growable: false) ??
        const [];
    _applicationCache = applications;
    return applications;
  }

  /// Load one visible application icon without blocking catalog discovery.
  /// Requests produced by the same list frame are combined into one platform
  /// call and both successful and unavailable icons are cached.
  Future<Uint8List?> loadApplicationIcon(String packageName) {
    if (_iconCache.containsKey(packageName)) {
      final icon = _iconCache.remove(packageName);
      _iconCache[packageName] = icon;
      return Future.value(icon);
    }
    final pending = _pendingIcons[packageName];
    if (pending != null) return pending.future;

    final completer = Completer<Uint8List?>();
    _pendingIcons[packageName] = completer;
    _queuedIcons.add(packageName);
    _iconBatchTimer ??= Timer(const Duration(milliseconds: 8), _flushIconBatch);
    return completer.future;
  }

  Future<void> _flushIconBatch() async {
    _iconBatchTimer = null;
    final packages = _queuedIcons.take(_maxIconBatchSize).toList();
    _queuedIcons.removeAll(packages);

    Map<Object?, Object?>? values;
    try {
      values = await _channel.invokeMapMethod<Object?, Object?>(
        'loadAppIcons',
        {'packages': packages},
      );
    } on PlatformException {
      // Icons are optional; a package resource failure keeps the placeholder.
    }
    for (final packageName in packages) {
      final icon = values?[packageName] as Uint8List?;
      _rememberIcon(packageName, icon);
      _pendingIcons.remove(packageName)?.complete(icon);
    }
    if (_queuedIcons.isNotEmpty) {
      _iconBatchTimer = Timer(Duration.zero, _flushIconBatch);
    }
  }

  void _rememberIcon(String packageName, Uint8List? icon) {
    _iconCache.remove(packageName);
    _iconCache[packageName] = icon;
    while (_iconCache.length > _maxCachedIcons) {
      _iconCache.remove(_iconCache.keys.first);
    }
  }

  @visibleForTesting
  Future<void> disposeForTesting() async {
    _iconBatchTimer?.cancel();
    for (final completer in _pendingIcons.values) {
      completer.complete(null);
    }
    _pendingIcons.clear();
    _queuedIcons.clear();
    _channel.setMethodCallHandler(null);
    await _states.close();
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
