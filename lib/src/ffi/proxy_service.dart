import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

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

  // Native callback pointer (must be kept alive)
  static Pointer<NativeFunction<LogCallbackNative>>? _nativeCallback;
  static ReceivePort? _logPort;

  /// Initialize logging system with FFI callback.
  void initLogging() {
    if (_loggingInitialized) return;

    // Set up isolate-based log receiving
    _logPort = ReceivePort();
    _logPort!.listen((message) {
      if (message is List && message.length == 2) {
        _logController.add(LogEntry(
          level: message[0] as int,
          message: message[1] as String,
        ));
      }
    });

    // Note: Dart FFI callbacks from native code run on the main isolate,
    // so we can directly add to the stream controller
    _nativeCallback = Pointer.fromFunction<LogCallbackNative>(_logCallback);
    _ffi.proxySetLogCallback(_nativeCallback!);
    _ffi.proxyInitLogging();
    _loggingInitialized = true;
  }

  static void _logCallback(int level, Pointer<Utf8> message) {
    final msg = message.toDartString();
    _logController.add(LogEntry(level: level, message: msg));
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
  }) async {
    if (_handle == null) {
      if (!create()) return ProxyResult.runtimeError;
    }

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
    _logPort?.close();
  }
}
