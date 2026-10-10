import 'package:proxy_ui/l10n/app_language.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/node_group_model.dart';
import '../models/node_model.dart';
import '../services/android_vpn_service.dart';
import 'proxy_ffi.dart';
import 'native_operation_queue.dart';

/// Log entry from native library.
class LogEntry {
  final int level;
  final String message;
  final DateTime timestamp;

  LogEntry({required this.level, required this.message, DateTime? timestamp})
    : timestamp = timestamp ?? DateTime.now();

  String get levelName {
    switch (level) {
      case 0:
        return 'TRACE';
      case 1:
        return 'DEBUG';
      case 2:
        return 'INFO';
      case 3:
        return 'WARN';
      case 4:
        return 'ERROR';
      default:
        return 'UNKNOWN';
    }
  }
}

/// Raw outcome of a node egress probe, before it becomes a persisted
/// [NodeVerification].
class NodeProbe {
  final bool success;
  final String countryCode;
  final String egressIp;
  final int? latencyMs;
  final String? error;

  const NodeProbe({
    required this.success,
    this.countryCode = '',
    this.egressIp = '',
    this.latencyMs,
    this.error,
  });
}

/// One live process instance used to reconstruct application parent/child trees.
class TunProcessInstance {
  final int pid;
  final int? parentPid;
  final String? executablePath;

  const TunProcessInstance({
    required this.pid,
    this.parentPid,
    this.executablePath,
  });

  factory TunProcessInstance.fromJson(Map<String, dynamic> json) {
    return TunProcessInstance(
      pid: (json['pid'] as num?)?.toInt() ?? 0,
      parentPid: (json['parent_pid'] as num?)?.toInt(),
      executablePath: json['executable_path'] as String?,
    );
  }
}

/// Grouped Windows process information returned by the native TUN picker API.
class TunProcessInfo {
  final String name;
  final String displayName;
  final List<String> aliases;
  final bool installed;
  final List<int> pids;
  final List<String> executablePaths;
  final List<TunProcessInstance> instances;
  final Uint8List? iconPng;

  const TunProcessInfo({
    required this.name,
    String? displayName,
    this.aliases = const [],
    this.installed = false,
    required this.pids,
    required this.executablePaths,
    this.instances = const [],
    this.iconPng,
  }) : displayName = displayName ?? name;

  factory TunProcessInfo.fromJson(Map<String, dynamic> json) {
    return TunProcessInfo(
      name: json['name'] as String? ?? '',
      displayName: json['display_name'] as String?,
      aliases: (json['aliases'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      installed: json['installed'] as bool? ?? false,
      pids: (json['pids'] as List<dynamic>? ?? const [])
          .whereType<num>()
          .map((pid) => pid.toInt())
          .toList(growable: false),
      executablePaths: (json['executable_paths'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      instances: (json['instances'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TunProcessInstance.fromJson)
          .where((instance) => instance.pid > 0)
          .toList(growable: false),
      iconPng: _decodeProcessIcon(json['icon_png_base64']),
    );
  }
}

Uint8List? _decodeProcessIcon(Object? encoded) {
  if (encoded is! String || encoded.isEmpty) return null;
  try {
    return base64Decode(encoded);
  } on FormatException {
    return null;
  }
}

/// High-level proxy service wrapping FFI calls.
class ProxyService {
  Stream<void> get connectionChanges => const Stream<void>.empty();
  Future<void> initializePlatform() async {}
  static const int defaultLogLevel = 2;

  final ProxyFFI _ffi = ProxyFFI();
  Pointer<Void>? _handle;
  bool _loggingInitialized = false;
  final NativeOperationQueue _operations = NativeOperationQueue();
  bool _runningSnapshot = false;
  bool _tunSnapshot = false;
  String? _errorSnapshot;

  Future<T> _withHandle<T>(Future<T> Function() operation) {
    return _operations.run(() async {
      try {
        return await operation();
      } finally {
        final handle = _handle;
        if (handle != null && handle != nullptr) {
          _runningSnapshot = _ffi.proxyIsRunning(handle) == 1;
          _tunSnapshot = _ffi.proxyIsTunRunning(handle) == 1;
          _errorSnapshot = _readLastError();
        }
      }
    });
  }

  String? _platformLastError;
  StreamSubscription<AndroidVpnStateEvent>? _androidVpnSubscription;

  ProxyService() {
    if (Platform.isAndroid) {
      _androidVpnSubscription = AndroidVpnService.instance.states.listen((
        event,
      ) {
        if (_operations.isClosed) return;
        final handle = _handle;
        if (!event.running && handle != null && handle != nullptr) {
          _platformLastError = event.error;
          if (isTunRunning) {
            unawaited(stopTun());
          }
        }
      });
    }
  }

  // Log callback handling
  static final _logController = StreamController<LogEntry>.broadcast();
  static Stream<LogEntry> get logStream => _logController.stream;

  /// Pushes an entry through the same stream the native log callback uses.
  @visibleForTesting
  static void debugEmitLog(LogEntry entry) => _logController.add(entry);

  // NativeCallable for thread-safe callback from native code
  static NativeCallable<LogCallbackNative>? _nativeCallable;

  /// Initialize logging system with FFI callback.
  void initLogging() {
    if (_loggingInitialized) return;

    // Use NativeCallable.listener for thread-safe callbacks from native threads
    // Native callbacks can already be queued when a service is disposed. Keep
    // one callback alive for the UI isolate's lifetime, including queued frees.
    _nativeCallable ??= NativeCallable<LogCallbackNative>.listener(_logCallback)
      ..keepIsolateAlive = false;
    _ffi.proxySetLogCallback(_nativeCallable!.nativeFunction);
    _ffi.proxySetLogLevel(defaultLogLevel);
    _ffi.proxyInitLogging();
    _loggingInitialized = true;
  }

  void setLogLevel(int level) {
    _ffi.proxySetLogLevel(level.clamp(0, 4));
  }

  static void _logCallback(int level, Pointer<Utf8> message) {
    try {
      if (message == nullptr) return;
      final msg = message.toDartString();
      _logController.add(LogEntry(level: level, message: msg));
    } catch (e) {
      // Ignore UTF-8 decode errors
    } finally {
      // Free the string allocated by Rust
      if (message != nullptr) {
        ProxyFFI().proxyFreeString(message);
      }
    }
  }

  /// Create proxy handle.
  bool create() {
    if (_operations.isClosed) return false;
    if (_handle != null && _handle != nullptr) return true;
    _handle = _ffi.proxyCreate();
    return _handle != null && _handle != nullptr;
  }

  /// Start proxy with configuration.
  Future<int> start({
    required String serverHost,
    required int serverPort,
    int localPort = 1080,
    String? sessionKey,
    bool autoProxy = true,
    bool udpEnabled = true,
    bool udpDirectFallback = true,
    bool tunEnabled = false,
    bool tunFakeIp = false,
    String tunDnsServer = '8.8.8.8',
    List<String> tunBypassProcesses = const [],
    bool reverseGeo = false,
    String? needCodecIps,
    bool forceCodec = false,
    bool secureTransport = false,
    bool setSystemProxy = false,
    bool allowLan = false,
  }) => _withHandle(() async {
    if (Platform.isAndroid) {
      await stopAndroidVpnInterface();
    }
    // Always recreate handle to apply new config
    await _destroyHandle();
    if (!create()) return ProxyResult.runtimeError;

    final config = calloc<ProxyConfigV8>();
    Pointer<Utf8>? serverHostPtr;
    Pointer<Utf8>? sessionKeyPtr;
    Pointer<Utf8>? cacheDirPtr;
    Pointer<Utf8>? needCodecIpsPtr;
    Pointer<Utf8>? tunBypassProcessesPtr;
    Pointer<Utf8>? tunDnsServerPtr;

    try {
      tunDnsServerPtr = tunDnsServer.toNativeUtf8();
      final dnsResult = _ffi.proxySetTunDnsServer(_handle!, tunDnsServerPtr);
      if (dnsResult != ProxyResult.ok) return dnsResult;
      serverHostPtr = serverHost.toNativeUtf8();
      config.ref.base.base.serverHost = serverHostPtr;
      config.ref.base.base.serverPort = serverPort;
      config.ref.base.base.localPort = localPort;

      if (sessionKey != null && sessionKey.length == 32) {
        sessionKeyPtr = sessionKey.toNativeUtf8();
        config.ref.base.base.sessionKey = sessionKeyPtr;
      } else {
        config.ref.base.base.sessionKey = nullptr;
      }

      config.ref.base.base.autoProxy = autoProxy ? 1 : 0;
      config.ref.base.base.enableUdp = udpEnabled ? 1 : 0;
      config.ref.base.base.tunUdpDirectFallback = udpDirectFallback ? 1 : 0;
      config.ref.base.base.enableTun = tunEnabled ? 1 : 0;
      config.ref.base.base.reverseGeo = reverseGeo ? 1 : 0;
      config.ref.base.base.allowLan = allowLan ? 1 : 0;

      // A stable private support directory keeps auto-proxy and virtual-DNS
      // state across process restarts and in-place upgrades on every platform.
      final supportDir = await getApplicationSupportDirectory();
      cacheDirPtr = supportDir.path.toNativeUtf8();
      config.ref.base.base.cacheDir = cacheDirPtr;

      if (needCodecIps != null && needCodecIps.isNotEmpty) {
        needCodecIpsPtr = needCodecIps.toNativeUtf8();
        config.ref.base.base.needCodecIps = needCodecIpsPtr;
      } else {
        config.ref.base.base.needCodecIps = nullptr;
      }

      config.ref.base.base.forceCodec = forceCodec ? 1 : 0;

      // Desktop platforms: set system proxy
      config.ref.base.base.setSystemProxy =
          (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
              setSystemProxy
          ? 1
          : 0;

      if (tunBypassProcesses.isNotEmpty) {
        tunBypassProcessesPtr = jsonEncode(tunBypassProcesses).toNativeUtf8();
        config.ref.base.base.tunBypassProcesses = tunBypassProcessesPtr;
      } else {
        config.ref.base.base.tunBypassProcesses = nullptr;
      }

      config.ref.base.wireProtocol = secureTransport ? 3 : 0;
      config.ref.tunFakeIp = tunFakeIp ? 1 : 0;
      return _ffi.proxyStartV8(_handle!, config);
    } finally {
      if (tunDnsServerPtr != null) calloc.free(tunDnsServerPtr);
      if (serverHostPtr != null) calloc.free(serverHostPtr);
      if (sessionKeyPtr != null) calloc.free(sessionKeyPtr);
      if (cacheDirPtr != null) calloc.free(cacheDirPtr);
      if (needCodecIpsPtr != null) calloc.free(needCodecIpsPtr);
      if (tunBypassProcessesPtr != null) {
        calloc.free(tunBypassProcessesPtr);
      }
      calloc.free(config);
    }
  });

  /// List normalized running executable names available for TUN bypass.
  List<String> listTunProcesses() {
    final pointer = _ffi.proxyListTunProcesses();
    if (pointer == nullptr) return const [];
    try {
      final decoded = jsonDecode(pointer.toDartString());
      if (decoded is! List<dynamic>) return const [];
      return decoded.whereType<String>().toList(growable: false);
    } finally {
      _ffi.proxyFreeString(pointer);
    }
  }

  /// List grouped process names, PIDs, and executable paths for the picker.
  List<TunProcessInfo> listTunProcessDetails() {
    final pointer = _ffi.proxyListTunProcessesV2();
    if (pointer == nullptr) return const [];
    try {
      final decoded = jsonDecode(pointer.toDartString());
      if (decoded is! List<dynamic>) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TunProcessInfo.fromJson)
          .where((process) => process.name.isNotEmpty)
          .toList(growable: false);
    } finally {
      _ffi.proxyFreeString(pointer);
    }
  }

  /// Return the executable name native code always excludes from TUN.
  String? get tunSelfProcess {
    final pointer = _ffi.proxyGetTunSelfProcess();
    if (pointer == nullptr) return null;
    try {
      return pointer.toDartString();
    } finally {
      _ffi.proxyFreeString(pointer);
    }
  }

  /// Detailed native failure for the last operation on this handle.
  ///
  /// The numeric ABI result is intentionally coarse and stable. This string
  /// carries actionable TUN stage, adapter, route, and Windows error context.
  String? get lastError =>
      _operations.isBusy ? _errorSnapshot : _readLastError();

  String? _readLastError() {
    if (_platformLastError case final error? when error.trim().isNotEmpty) {
      return error.trim();
    }
    final handle = _handle;
    if (handle == null || handle == nullptr) return null;
    final pointer = _ffi.proxyGetLastError(handle);
    if (pointer == nullptr) return null;
    try {
      final message = pointer.toDartString().trim();
      return message.isEmpty ? null : message;
    } finally {
      _ffi.proxyFreeString(pointer);
    }
  }

  /// Apply a new TUN process policy without recreating the TUN device.
  int setTunBypassProcesses(List<String> processes) {
    if (_operations.isBusy || _operations.isClosed) {
      return ProxyResult.runtimeError;
    }
    if (_handle == null) return ProxyResult.notRunning;
    final pointer = processes.isEmpty
        ? nullptr
        : jsonEncode(processes).toNativeUtf8();
    try {
      return _ffi.proxySetTunBypassProcesses(_handle!, pointer);
    } finally {
      if (pointer != nullptr) calloc.free(pointer);
    }
  }

  /// Replace the remote endpoint while preserving the bound local proxy port.
  ///
  /// Native code refuses this operation while TUN routes are active. The
  /// provider therefore stops only TUN, switches this endpoint, and starts TUN
  /// again so its mandatory remote route bypass follows the new node.
  int switchUpstream({required String serverHost, required int serverPort}) {
    if (_operations.isBusy || _operations.isClosed) {
      return ProxyResult.runtimeError;
    }
    if (_handle == null) return ProxyResult.notRunning;
    final serverHostPtr = serverHost.toNativeUtf8();
    try {
      return _ffi.proxySwitchUpstream(_handle!, serverHostPtr, serverPort);
    } finally {
      calloc.free(serverHostPtr);
    }
  }

  static int _startTunIsolate(Map<String, dynamic> params) {
    final ffi = ProxyFFI();
    final handle = Pointer<Void>.fromAddress(params['handleAddress'] as int);
    final processes = (params['processes'] as List<dynamic>).cast<String>();
    final pointer = processes.isEmpty
        ? nullptr
        : jsonEncode(processes).toNativeUtf8();
    try {
      return ffi.proxyStartTun(handle, pointer);
    } finally {
      if (pointer != nullptr) calloc.free(pointer);
    }
  }

  /// Enable TUN only after the local proxy listener has started. Native setup
  /// can wait for adapter and route readiness, so it runs outside the UI isolate.
  Future<int> startTun(List<String> processes) => _withHandle(() async {
    if (_handle == null) return ProxyResult.notRunning;
    return compute(_startTunIsolate, {
      'handleAddress': _handle!.address,
      'processes': processes,
    });
  });

  static int _startAndroidTunIsolate(Map<String, int> params) {
    final ffi = ProxyFFI();
    return ffi.proxyStartAndroidTun(
      Pointer<Void>.fromAddress(params['handleAddress']!),
      params['tunFd']!,
      params['mtu']!,
    );
  }

  /// Establish Android's VpnService interface, then hand a duplicated TUN
  /// descriptor to Rust. The service retains the original descriptor.
  Future<int> startAndroidTun({
    required String mode,
    required List<String> packages,
  }) => _withHandle(() async {
    final handle = _handle;
    if (!Platform.isAndroid || handle == null || handle == nullptr) {
      return ProxyResult.notRunning;
    }
    _platformLastError = null;
    try {
      final interface = await AndroidVpnService.instance.startInterface(
        mode: mode,
        packages: packages,
      );
      _logController.add(
        LogEntry(level: 2, message: '[android_vpn] ${interface.diagnostics}'),
      );
      final result = await compute(_startAndroidTunIsolate, {
        'handleAddress': handle.address,
        'tunFd': interface.fileDescriptor,
        'mtu': interface.mtu,
      });
      if (result == ProxyResult.ok) {
        final network = await AndroidVpnService.instance.waitForValidation();
        _logController.add(
          LogEntry(
            level: network.validated ? 2 : 4,
            message: '[android_vpn] ${network.diagnostics}',
          ),
        );
        if (!network.validated) {
          _platformLastError = appStrings.androidVpnValidationFailed(
            network.diagnostics,
          );
          await compute(_stopTunIsolate, handle.address);
          await AndroidVpnService.instance.stopInterface();
          return ProxyResult.runtimeError;
        }
      } else {
        await AndroidVpnService.instance.stopInterface();
      }
      return result;
    } on PlatformException catch (error) {
      _platformLastError = error.message ?? error.code;
      return ProxyResult.runtimeError;
    }
  });

  static int _stopTunIsolate(int handleAddress) {
    final ffi = ProxyFFI();
    return ffi.proxyStopTun(Pointer<Void>.fromAddress(handleAddress));
  }

  /// Stop TUN capture without stopping the local HTTP/SOCKS5 listener. Route
  /// cleanup can briefly block, so it also stays outside the UI isolate.
  Future<int> stopTun() => _withHandle(() async {
    if (_handle == null) return ProxyResult.notRunning;
    return compute(_stopTunIsolate, _handle!.address);
  });

  Future<int> stopAndroidTun() async {
    if (!Platform.isAndroid) return ProxyResult.invalidParam;
    _platformLastError = null;
    final result = await stopTun();
    try {
      await AndroidVpnService.instance.stopInterface();
    } on PlatformException catch (error) {
      _platformLastError = error.message ?? error.code;
      return ProxyResult.runtimeError;
    }
    return result;
  }

  Future<List<AndroidVpnApplication>> listAndroidVpnApplications({
    bool forceRefresh = false,
  }) {
    if (!Platform.isAndroid) return Future.value(const []);
    return AndroidVpnService.instance.listInstalledApps(
      forceRefresh: forceRefresh,
    );
  }

  Future<void> stopAndroidVpnInterface() async {
    if (!Platform.isAndroid) return;
    try {
      await AndroidVpnService.instance.stopInterface();
    } on PlatformException catch (error) {
      _platformLastError = error.message ?? error.code;
    }
  }

  bool get isTunRunning {
    if (_operations.isBusy) return _tunSnapshot;
    if (_handle == null) return false;
    return _ffi.proxyIsTunRunning(_handle!) == 1;
  }

  /// Windows UAC helpers. A negative elevation result is treated as not
  /// elevated so native startup still refuses route changes safely.
  bool get isElevated => !Platform.isWindows || _ffi.proxyIsElevated() == 1;

  int relaunchElevatedForTun() {
    if (!Platform.isWindows) return ProxyResult.invalidParam;
    return _ffi.proxyRelaunchElevatedForTun();
  }

  /// Puts back a system proxy that a previous run took over but never released.
  ///
  /// Returns true when leftover settings were found and restored.
  bool restoreOrphanedSystemProxy() {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return false;
    }
    try {
      return _ffi.proxyRestoreSystemProxy() == 1;
    } on ArgumentError {
      // An older native library without the export. Nothing to recover from.
      return false;
    }
  }

  static int _stopIsolate(int handleAddress) {
    final ffi = ProxyFFI();
    return ffi.proxyStop(Pointer<Void>.fromAddress(handleAddress));
  }

  /// Stop the proxy, and any TUN session it owns.
  ///
  /// Native code waits for TUN teardown to restore the system routes and DNS
  /// before returning, so this stays off the UI isolate for the same reason
  /// [stopTun] does.
  Future<int> stop() => _withHandle(() async {
    if (_handle == null) return ProxyResult.invalidParam;
    await stopAndroidVpnInterface();
    return compute(_stopIsolate, _handle!.address);
  });

  /// Destroy the handle after pending native operations have finished.
  Future<void> destroy() => _withHandle(_destroyHandle);

  static void _destroyIsolate(int address) {
    ProxyFFI().proxyDestroy(Pointer<Void>.fromAddress(address));
  }

  Future<void> _destroyHandle() async {
    final handle = _handle;
    _handle = null;
    _runningSnapshot = false;
    _tunSnapshot = false;
    if (handle != null && handle != nullptr) {
      await compute(_destroyIsolate, handle.address);
    }
  }

  /// Check if proxy is running.
  bool get isRunning {
    if (_operations.isBusy) return _runningSnapshot;
    if (_handle == null) return false;
    return _ffi.proxyIsRunning(_handle!) == 1;
  }

  /// Dispose resources.
  void dispose() {
    _androidVpnSubscription?.cancel();
    unawaited(
      _operations
          .close(() async {
            final handle = _handle;
            if (handle == null || handle == nullptr) return;
            // The queue retains the pointer until every isolate has returned.
            try {
              await stopAndroidVpnInterface();
              await compute(_stopIsolate, handle.address);
            } finally {
              await _destroyHandle();
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            debugPrint('Native proxy cleanup failed: $error\n$stackTrace');
          }),
    );
  }

  // Isolate entry point for ping test
  static Future<Map<String, dynamic>> _testLatencyIsolate(
    Map<String, dynamic> params,
  ) async {
    final ffi = ProxyFFI();
    final handle = Pointer<Void>.fromAddress(params['handleAddress'] as int);
    final testUrl = params['testUrl'] as String?;
    final timeoutMs = params['timeoutMs'] as int;

    final urlPtr = testUrl != null ? testUrl.toNativeUtf8() : nullptr;

    try {
      final result = ffi.proxyTestLatency(handle, urlPtr, timeoutMs);

      try {
        if (result.success == 1) {
          return {'success': true, 'latencyMs': result.latencyMs};
        } else {
          final error = result.error == nullptr
              ? null
              : result.error.toDartString();
          return {'success': false, 'error': error};
        }
      } finally {
        // Free the error string allocated by Rust (if any)
        if (result.error != nullptr) {
          ffi.proxyFreeString(result.error);
        }
      }
    } finally {
      if (urlPtr != nullptr) calloc.free(urlPtr);
    }
  }

  /// Test proxy latency (only works when proxy is running).
  /// Tests real-world latency by sending HTTPS request through local proxy.
  Future<int?> testLatency({String? testUrl, int timeoutMs = 10000}) =>
      _withHandle(() async {
        if (_handle == null) throw StateError(appStrings.proxyNotInitialized);

        final result = await compute(_testLatencyIsolate, {
          'handleAddress': _handle!.address,
          'testUrl': testUrl,
          'timeoutMs': timeoutMs,
        });

        if (result['success'] == true) {
          return result['latencyMs'] as int;
        } else {
          throw Exception(result['error'] ?? appStrings.latencyTestFailed);
        }
      });

  // Isolate entry point for node listing
  static Future<Map<String, dynamic>> _getServerNodesIsolate(
    Map<String, dynamic> params,
  ) async {
    final ffi = ProxyFFI();
    final serverHost = params['serverHost'] as String;
    final serverPort = params['serverPort'] as int;
    final sessionKey = params['sessionKey'] as String?;
    final timeoutMs = params['timeoutMs'] as int;

    final hostPtr = serverHost.toNativeUtf8();
    final keyPtr = sessionKey?.toNativeUtf8() ?? nullptr;

    try {
      final result = ffi.proxyGetServerNodes(
        hostPtr,
        serverPort,
        keyPtr,
        timeoutMs,
      );

      try {
        if (result.success == 1) {
          final nodes = <Map<String, dynamic>>[];
          for (int i = 0; i < result.count; i++) {
            final node = (result.nodes + i).ref;
            nodes.add({
              'nodeId': node.nodeId.toDartString(),
              'addr': node.addr.toDartString(),
              'lastSeenMs': node.lastSeenMs,
              'country': node.country.toDartString(),
              'region': node.region.toDartString(),
            });
          }
          return {'success': true, 'nodes': nodes};
        } else {
          final error = result.error == nullptr
              ? null
              : result.error.toDartString();
          return {'success': false, 'error': error};
        }
      } finally {
        // Free the NodesResult allocated by Rust
        // We need to allocate a pointer to pass to the free function
        final resultPtr = calloc<NodesResult>();
        resultPtr.ref.success = result.success;
        resultPtr.ref.nodes = result.nodes;
        resultPtr.ref.count = result.count;
        resultPtr.ref.error = result.error;
        ffi.proxyFreeNodesResult(resultPtr);
        calloc.free(resultPtr);
      }
    } finally {
      calloc.free(hostPtr);
      if (keyPtr != nullptr) calloc.free(keyPtr);
    }
  }

  /// Asks an echo service, through `serverHost`, where its traffic egresses.
  ///
  /// Runs off the UI isolate because it opens a real connection through the
  /// node and waits for an answer.
  static Future<Map<String, dynamic>> _probeNodeIsolate(
    Map<String, dynamic> params,
  ) async {
    final ffi = ProxyFFI();
    final hostPtr = (params['serverHost'] as String).toNativeUtf8();

    try {
      final result = ffi.proxyProbeNodeV3(
        hostPtr,
        params['serverPort'] as int,
        (params['forceCodec'] as bool) ? 1 : 0,
        params['timeoutMs'] as int,
        (params['secureTransport'] as bool) ? 3 : 0,
      );

      try {
        if (result.success == 1) {
          return {
            'success': true,
            'countryCode': result.countryCode == nullptr
                ? ''
                : result.countryCode.toDartString(),
            'egressIp': result.egressIp == nullptr
                ? ''
                : result.egressIp.toDartString(),
            'latencyMs': result.latencyMs,
          };
        }
        return {
          'success': false,
          'latencyMs': result.latencyMs,
          'error': result.error == nullptr ? null : result.error.toDartString(),
        };
      } finally {
        final resultPtr = calloc<NodeProbeResult>();
        resultPtr.ref
          ..success = result.success
          ..countryCode = result.countryCode
          ..egressIp = result.egressIp
          ..latencyMs = result.latencyMs
          ..error = result.error;
        ffi.proxyFreeNodeProbeResult(resultPtr);
        calloc.free(resultPtr);
      }
    } finally {
      calloc.free(hostPtr);
    }
  }

  /// Verifies a node's real egress country.
  Future<NodeProbe> probeNode({
    required String serverHost,
    required int serverPort,
    bool forceCodec = false,
    bool secureTransport = false,
    int timeoutMs = 10000,
  }) async {
    final result = await compute(_probeNodeIsolate, {
      'serverHost': serverHost,
      'serverPort': serverPort,
      'forceCodec': forceCodec,
      'secureTransport': secureTransport,
      'timeoutMs': timeoutMs,
    });

    final latency = result['latencyMs'];
    return NodeProbe(
      success: result['success'] == true,
      countryCode: (result['countryCode'] as String?) ?? '',
      egressIp: (result['egressIp'] as String?) ?? '',
      latencyMs: latency is int ? latency : null,
      error:
          result['error'] as String? ??
          (result['success'] == true
              ? null
              : appStrings.nodeVerificationFailed),
    );
  }

  // Isolate entry point for group listing
  static Future<Map<String, dynamic>> _getServerGroupsIsolate(
    Map<String, dynamic> params,
  ) async {
    final ffi = ProxyFFI();
    final serverHost = params['serverHost'] as String;
    final serverPort = params['serverPort'] as int;
    final sessionKey = params['sessionKey'] as String?;
    final timeoutMs = params['timeoutMs'] as int;

    final hostPtr = serverHost.toNativeUtf8();
    final keyPtr = sessionKey?.toNativeUtf8() ?? nullptr;

    try {
      final result = ffi.proxyGetServerGroups(
        hostPtr,
        serverPort,
        keyPtr,
        timeoutMs,
      );

      try {
        if (result.success == 1) {
          final groups = <Map<String, dynamic>>[];
          for (int i = 0; i < result.count; i++) {
            final group = (result.groups + i).ref;
            final nodeIds = <String>[];
            for (int j = 0; j < group.nodeIdsCount; j++) {
              final nodeIdPtr = (group.nodeIds + j).value;
              nodeIds.add(nodeIdPtr.toDartString());
            }
            groups.add({
              'groupId': group.groupId.toDartString(),
              'name': group.name.toDartString(),
              'nodeIds': nodeIds,
              'createdAtMs': group.createdAtMs,
            });
          }
          return {'success': true, 'groups': groups};
        } else {
          final error = result.error == nullptr
              ? null
              : result.error.toDartString();
          return {'success': false, 'error': error};
        }
      } finally {
        // Free the GroupsResult allocated by Rust
        final resultPtr = calloc<GroupsResult>();
        resultPtr.ref.success = result.success;
        resultPtr.ref.groups = result.groups;
        resultPtr.ref.count = result.count;
        resultPtr.ref.error = result.error;
        ffi.proxyFreeGroupsResult(resultPtr);
        calloc.free(resultPtr);
      }
    } finally {
      calloc.free(hostPtr);
      if (keyPtr != nullptr) calloc.free(keyPtr);
    }
  }

  /// Get all nodes from server with geo location info.
  Future<List<NodeInfo>> getServerNodes({
    required String serverHost,
    required int serverPort,
    String? sessionKey,
    int timeoutMs = 10000,
  }) async {
    final result = await compute(_getServerNodesIsolate, {
      'serverHost': serverHost,
      'serverPort': serverPort,
      'sessionKey': sessionKey,
      'timeoutMs': timeoutMs,
    });

    if (result['success'] == true) {
      final nodesList = result['nodes'] as List;
      return nodesList
          .map(
            (n) => NodeInfo(
              nodeId: n['nodeId'],
              addr: n['addr'],
              lastSeen: DateTime.fromMillisecondsSinceEpoch(n['lastSeenMs']),
              country: n['country'],
              region: n['region'],
            ),
          )
          .toList();
    } else {
      throw Exception(result['error'] ?? appStrings.failedToGetNodes);
    }
  }

  /// Get all node groups from server.
  Future<List<NodeGroupModel>> getServerGroups({
    required String serverHost,
    required int serverPort,
    String? sessionKey,
    int timeoutMs = 10000,
  }) async {
    final result = await compute(_getServerGroupsIsolate, {
      'serverHost': serverHost,
      'serverPort': serverPort,
      'sessionKey': sessionKey,
      'timeoutMs': timeoutMs,
    });

    if (result['success'] == true) {
      final groupsList = result['groups'] as List;
      return groupsList
          .map(
            (g) => NodeGroupModel(
              groupId: g['groupId'],
              name: g['name'],
              nodeIds: List<String>.from(g['nodeIds'] as List),
              createdAt: DateTime.fromMillisecondsSinceEpoch(g['createdAtMs']),
            ),
          )
          .toList();
    } else {
      throw Exception(result['error'] ?? appStrings.failedToGetGroups);
    }
  }
}
