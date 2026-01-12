import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/node_model.dart';
import 'proxy_ffi.dart';

/// Log entry from native library.
class LogEntry {
  final int level;
  final String message;
  final DateTime timestamp;

  LogEntry({required this.level, required this.message})
    : timestamp = DateTime.now();

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

/// High-level proxy service wrapping FFI calls.
class ProxyService {
  final ProxyFFI _ffi = ProxyFFI();
  Pointer<Void>? _handle;
  bool _loggingInitialized = false;

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
    _ffi.proxyInitLogging();
    _loggingInitialized = true;
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
    bool reverseGeo = false,
    String? needCodecIps,
    bool forceCodec = false,
    bool setSystemProxy = false,
  }) async {
    // Always recreate handle to apply new config
    destroy();
    if (!create()) return ProxyResult.runtimeError;

    final config = calloc<ProxyConfig>();
    Pointer<Utf8>? serverHostPtr;
    Pointer<Utf8>? sessionKeyPtr;
    Pointer<Utf8>? cacheDirPtr;
    Pointer<Utf8>? needCodecIpsPtr;

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
      config.ref.reverseGeo = reverseGeo ? 1 : 0;

      // Mobile platforms need cache_dir for auto-proxy
      if (Platform.isAndroid || Platform.isIOS) {
        final dir = await getApplicationDocumentsDirectory();
        cacheDirPtr = dir.path.toNativeUtf8();
        config.ref.cacheDir = cacheDirPtr;
      } else {
        config.ref.cacheDir = nullptr;
      }

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

      return _ffi.proxyStart(_handle!, config);
    } finally {
      if (serverHostPtr != null) calloc.free(serverHostPtr);
      if (sessionKeyPtr != null) calloc.free(sessionKeyPtr);
      if (cacheDirPtr != null) calloc.free(cacheDirPtr);
      if (needCodecIpsPtr != null) calloc.free(needCodecIpsPtr);
      calloc.free(config);
    }
  }

  /// Stop proxy.
  int stop() {
    if (_handle == null) return ProxyResult.invalidParam;
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
    destroy();
    _nativeCallable?.close();
  }

  // Isolate entry point for ping test
  static Future<Map<String, dynamic>> _testLatencyIsolate(
      Map<String, dynamic> params) async {
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
      Map<String, dynamic> params) async {
    final ffi = ProxyFFI();
    final serverHost = params['serverHost'] as String;
    final serverPort = params['serverPort'] as int;
    final sessionKey = params['sessionKey'] as String?;
    final timeoutMs = params['timeoutMs'] as int;

    final hostPtr = serverHost.toNativeUtf8();
    final keyPtr = sessionKey?.toNativeUtf8() ?? nullptr;

    try {
      final result =
          ffi.proxyGetServerNodes(hostPtr, serverPort, keyPtr, timeoutMs);

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
          .map((n) => NodeInfo(
                nodeId: n['nodeId'],
                addr: n['addr'],
                lastSeen: DateTime.fromMillisecondsSinceEpoch(n['lastSeenMs']),
                country: n['country'],
                region: n['region'],
              ))
          .toList();
    } else {
      throw Exception(result['error'] ?? 'Failed to get nodes');
    }
  }
}
