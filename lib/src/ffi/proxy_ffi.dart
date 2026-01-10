import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Log callback function type.
/// level: 0=trace, 1=debug, 2=info, 3=warn, 4=error
typedef LogCallbackNative = Void Function(Int32 level, Pointer<Utf8> message);

/// ProxyResult codes from FFI.
abstract class ProxyResult {
  static const int ok = 0;
  static const int invalidParam = -1;
  static const int connectionFailed = -2;
  static const int runtimeError = -3;
  static const int alreadyRunning = -4;
  static const int notRunning = -5;

  static String message(int code) {
    switch (code) {
      case ok:
        return 'OK';
      case invalidParam:
        return 'Invalid parameter';
      case connectionFailed:
        return 'Connection failed';
      case runtimeError:
        return 'Runtime error';
      case alreadyRunning:
        return 'Already running';
      case notRunning:
        return 'Not running';
      default:
        return 'Unknown error ($code)';
    }
  }
}

/// ProxyConfig structure matching C FFI.
final class ProxyConfig extends Struct {
  external Pointer<Utf8> serverHost;
  @Uint16()
  external int serverPort;
  @Uint16()
  external int localPort;
  external Pointer<Utf8> sessionKey;
  @Int32()
  external int autoProxy;
  @Int32()
  external int reverseGeo;
  external Pointer<Utf8> cacheDir;
  external Pointer<Utf8> needCodecIps;
  @Int32()
  external int forceCodec;
  @Int32()
  external int setSystemProxy; // desktop only: 0 = disabled, 1 = set system proxy
}

// FFI function signatures
typedef _ProxySetLogCallbackNative =
    Void Function(Pointer<NativeFunction<LogCallbackNative>> callback);
typedef _ProxySetLogCallbackDart =
    void Function(Pointer<NativeFunction<LogCallbackNative>> callback);

typedef _ProxyInitLoggingNative = Void Function();
typedef _ProxyInitLoggingDart = void Function();

typedef _ProxyCreateNative = Pointer<Void> Function();
typedef _ProxyCreateDart = Pointer<Void> Function();

typedef _ProxyStartNative =
    Int32 Function(Pointer<Void> handle, Pointer<ProxyConfig> config);
typedef _ProxyStartDart =
    int Function(Pointer<Void> handle, Pointer<ProxyConfig> config);

typedef _ProxyStopNative = Int32 Function(Pointer<Void> handle);
typedef _ProxyStopDart = int Function(Pointer<Void> handle);

typedef _ProxyDestroyNative = Void Function(Pointer<Void> handle);
typedef _ProxyDestroyDart = void Function(Pointer<Void> handle);

typedef _ProxyIsRunningNative = Int32 Function(Pointer<Void> handle);
typedef _ProxyIsRunningDart = int Function(Pointer<Void> handle);

typedef _ProxyFreeStringNative = Void Function(Pointer<Utf8> s);
typedef _ProxyFreeStringDart = void Function(Pointer<Utf8> s);

/// FFI bindings for proxy library.
class ProxyFFI {
  static ProxyFFI? _instance;
  static DynamicLibrary? _lib;

  ProxyFFI._();

  factory ProxyFFI() {
    _instance ??= ProxyFFI._();
    return _instance!;
  }

  DynamicLibrary get lib {
    _lib ??= _loadLibrary();
    return _lib!;
  }

  static DynamicLibrary _loadLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libhttp_proxy.so');
    } else if (Platform.isIOS) {
      // iOS static library is linked into the main executable
      return DynamicLibrary.process();
    } else if (Platform.isMacOS) {
      // Try app bundle first, then fallback to current directory
      try {
        return DynamicLibrary.open(
          '@executable_path/../Frameworks/libhttp_proxy.dylib',
        );
      } catch (_) {
        return DynamicLibrary.open('libhttp_proxy.dylib');
      }
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('http_proxy.dll');
    } else if (Platform.isLinux) {
      // Try relative path first (for bundled app), then system path
      try {
        return DynamicLibrary.open('lib/libhttp_proxy.so');
      } catch (_) {
        return DynamicLibrary.open('libhttp_proxy.so');
      }
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  late final proxySetLogCallback = lib
      .lookupFunction<_ProxySetLogCallbackNative, _ProxySetLogCallbackDart>(
        'proxy_set_log_callback',
      );

  late final proxyInitLogging = lib
      .lookupFunction<_ProxyInitLoggingNative, _ProxyInitLoggingDart>(
        'proxy_init_logging',
      );

  late final proxyCreate = lib
      .lookupFunction<_ProxyCreateNative, _ProxyCreateDart>('proxy_create');

  late final proxyStart = lib
      .lookupFunction<_ProxyStartNative, _ProxyStartDart>('proxy_start');

  late final proxyStop = lib.lookupFunction<_ProxyStopNative, _ProxyStopDart>(
    'proxy_stop',
  );

  late final proxyDestroy = lib
      .lookupFunction<_ProxyDestroyNative, _ProxyDestroyDart>('proxy_destroy');

  late final proxyIsRunning = lib
      .lookupFunction<_ProxyIsRunningNative, _ProxyIsRunningDart>(
        'proxy_is_running',
      );

  late final proxyFreeString = lib
      .lookupFunction<_ProxyFreeStringNative, _ProxyFreeStringDart>(
        'proxy_free_string',
      );
}
