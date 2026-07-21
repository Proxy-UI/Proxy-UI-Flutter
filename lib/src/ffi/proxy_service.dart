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
  static const int defaultLogLevel = 2;

  final ProxyFFI _ffi = ProxyFFI();
  Pointer<Void>? _handle;
  bool _loggingInitialized = false;
  String? _platformLastError;
  StreamSubscription<AndroidVpnStateEvent>? _androidVpnSubscription;

  ProxyService() {
    if (Platform.isAndroid) {
      _androidVpnSubscription = AndroidVpnService.instance.states.listen((
        event,
      ) {
        final handle = _handle;
        if (!event.running && handle != null && handle != nullptr) {
          _platformLastError = event.error;
          if (_ffi.proxyIsTunRunning(handle) == 1) {
            _ffi.proxyStopTun(handle);
          }
        }
      });
    }
  }

  // Log callback handling
  static final _logController = StreamController<LogEntry>.broadcast();
  static Stream<LogEntry> get logStream => _logController.stream;

  // NativeCallable for thread-safe callback from native code
  static NativeCallable<LogCallbackNative>? _nativeCallable;

  /// Initialize logging system with FFI callback.
  void initLogging() {
    if (_loggingInitialized) return;

    // Use NativeCallable.listener for thread-safe callbacks from native threads
    _nativeCallable = NativeCallable<LogCallbackNative>.listener(_logCallback);
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
    if (_handle != null) return true;
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
    List<String> tunBypassProcesses = const [],
    bool reverseGeo = false,
    String? needCodecIps,
    bool forceCodec = false,
    bool setSystemProxy = false,
  }) async {
    if (Platform.isAndroid) {
      await stopAndroidVpnInterface();
    }
    // Always recreate handle to apply new config
    destroy();
    if (!create()) return ProxyResult.runtimeError;

    final config = calloc<ProxyConfigV4>();
    Pointer<Utf8>? serverHostPtr;
    Pointer<Utf8>? sessionKeyPtr;
    Pointer<Utf8>? cacheDirPtr;
    Pointer<Utf8>? needCodecIpsPtr;
    Pointer<Utf8>? tunBypassProcessesPtr;

    try {
      serverHostPtr = serverHost.toNativeUtf8();
      config.ref.serverHost = serverHostPtr;
      config.ref.serverPort = serverPort;
      config.ref.localPort = localPort;

      if (sessionKey != null && sessionKey.length == 32) {
        sessionKeyPtr = sessionKey.toNativeUtf8();
        config.ref.sessionKey = sessionKeyPtr;
      } else {
        config.ref.sessionKey = nullptr;
      }

      config.ref.autoProxy = autoProxy ? 1 : 0;
      config.ref.enableUdp = udpEnabled ? 1 : 0;
      config.ref.tunUdpDirectFallback = udpDirectFallback ? 1 : 0;
      config.ref.enableTun = tunEnabled ? 1 : 0;
      config.ref.reverseGeo = reverseGeo ? 1 : 0;

      // A stable private support directory keeps auto-proxy and virtual-DNS
      // state across process restarts and in-place upgrades on every platform.
      final supportDir = await getApplicationSupportDirectory();
      cacheDirPtr = supportDir.path.toNativeUtf8();
      config.ref.cacheDir = cacheDirPtr;

      if (needCodecIps != null && needCodecIps.isNotEmpty) {
        needCodecIpsPtr = needCodecIps.toNativeUtf8();
        config.ref.needCodecIps = needCodecIpsPtr;
      } else {
        config.ref.needCodecIps = nullptr;
      }

      config.ref.forceCodec = forceCodec ? 1 : 0;

      // Desktop platforms: set system proxy
      config.ref.setSystemProxy =
          (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
              setSystemProxy
          ? 1
          : 0;

      if (tunBypassProcesses.isNotEmpty) {
        tunBypassProcessesPtr = jsonEncode(tunBypassProcesses).toNativeUtf8();
        config.ref.tunBypassProcesses = tunBypassProcessesPtr;
      } else {
        config.ref.tunBypassProcesses = nullptr;
      }

      return _ffi.proxyStartV4(_handle!, config);
    } finally {
      if (serverHostPtr != null) calloc.free(serverHostPtr);
      if (sessionKeyPtr != null) calloc.free(sessionKeyPtr);
      if (cacheDirPtr != null) calloc.free(cacheDirPtr);
      if (needCodecIpsPtr != null) calloc.free(needCodecIpsPtr);
      if (tunBypassProcessesPtr != null) {
        calloc.free(tunBypassProcessesPtr);
      }
      calloc.free(config);
    }
  }

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
  String? get lastError {
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
  Future<int> startTun(List<String> processes) async {
    if (_handle == null) return ProxyResult.notRunning;
    return compute(_startTunIsolate, {
      'handleAddress': _handle!.address,
      'processes': processes,
    });
  }

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
  }) async {
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
          _platformLastError =
              'Android did not validate the VPN network within 10 seconds: '
              '${network.diagnostics}; Google Play and background update '
              'schedulers may reject it before opening a connection.';
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
  }

  static int _stopTunIsolate(int handleAddress) {
    final ffi = ProxyFFI();
    return ffi.proxyStopTun(Pointer<Void>.fromAddress(handleAddress));
  }

  /// Stop TUN capture without stopping the local HTTP/SOCKS5 listener. Route
  /// cleanup can briefly block, so it also stays outside the UI isolate.
  Future<int> stopTun() async {
    if (_handle == null) return ProxyResult.notRunning;
    return compute(_stopTunIsolate, _handle!.address);
  }

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

  /// Stop proxy.
  int stop() {
    if (_handle == null) return ProxyResult.invalidParam;
    if (Platform.isAndroid) {
      unawaited(AndroidVpnService.instance.stopInterface());
    }
    return _ffi.proxyStop(_handle!);
  }

  /// Destroy proxy handle and free resources.
  void destroy() {
    if (_handle != null) {
      _ffi.proxyDestroy(_handle!);
      _handle = null;
    }
  }

  /// Check if proxy is running.
  bool get isRunning {
    if (_handle == null) return false;
    return _ffi.proxyIsRunning(_handle!) == 1;
  }

  /// Dispose resources.
  void dispose() {
    if (_handle != null) {
      stop();
    }
    destroy();
    _androidVpnSubscription?.cancel();
    _nativeCallable?.close();
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
          final error = result.error.toDartString();
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
  Future<int?> testLatency({String? testUrl, int timeoutMs = 10000}) async {
    if (_handle == null) throw StateError('Proxy not initialized');

    final result = await compute(_testLatencyIsolate, {
      'handleAddress': _handle!.address,
      'testUrl': testUrl,
      'timeoutMs': timeoutMs,
    });

    if (result['success'] == true) {
      return result['latencyMs'] as int;
    } else {
      throw Exception(result['error'] ?? 'Latency test failed');
    }
  }

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
          final error = result.error.toDartString();
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
          final error = result.error.toDartString();
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
      throw Exception(result['error'] ?? 'Failed to get nodes');
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
      throw Exception(result['error'] ?? 'Failed to get groups');
    }
  }
}
