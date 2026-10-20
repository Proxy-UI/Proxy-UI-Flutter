import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../ffi/native_proxy_operations.dart';
import '../ffi/proxy_ffi.dart';
import '../ffi/proxy_service.dart';
import 'apple_vpn_service.dart';
import 'build_capabilities.dart';

typedef LogDirectoryProvider = Future<Directory> Function();
typedef LogDirectoryOpener = Future<void> Function(String path);

abstract interface class DesktopLogBackend {
  Future<void> configure(String directory);
  void write(LogEntry entry);
  Future<void> flush();
}

typedef _WriteNative = Int32 Function(Int32, Pointer<Utf8>, Int64);
typedef _Write = int Function(int, Pointer<Utf8>, int);

class NativeDesktopLogBackend implements DesktopLogBackend {
  late final _write = ProxyFFI().lib.lookupFunction<_WriteNative, _Write>(
    'proxy_log_write_v1',
  );
  @override
  Future<void> configure(String directory) async {
    await NativeProxyOperations.shared.run(
      'configure_logs',
      arguments: {'directory': directory},
    );
  }

  @override
  void write(LogEntry entry) {
    final message = entry.message.replaceAll('\u0000', r'\0').toNativeUtf8();
    try {
      if (_write(
            entry.level,
            message,
            entry.timestamp.millisecondsSinceEpoch,
          ) !=
          0) {
        throw StateError('Native log writer is unavailable');
      }
    } finally {
      calloc.free(message);
    }
  }

  @override
  Future<void> flush() async {
    await NativeProxyOperations.shared.run('flush_logs');
  }
}

/// Rust owns buffering, rotation, retention and flush. Native entries have
/// already been persisted before their UI callback and never make a round trip.
class DesktopLogService {
  DesktopLogService({
    bool? enabled,
    DesktopLogBackend? backend,
    LogDirectoryProvider? directoryProvider,
    LogDirectoryOpener? directoryOpener,
  }) : enabled =
           enabled ??
           (Platform.isWindows || Platform.isLinux || Platform.isMacOS),
       _backend = backend ?? NativeDesktopLogBackend(),
       _directoryProvider = directoryProvider ?? _defaultDirectoryProvider,
       _directoryOpener = directoryOpener ?? _defaultDirectoryOpener;

  final bool enabled;
  final DesktopLogBackend _backend;
  final LogDirectoryProvider _directoryProvider;
  final LogDirectoryOpener _directoryOpener;
  Future<Directory>? _directory;
  Future<void> _pending = Future<void>.value();
  Future<void>? _disposed;
  bool _ready = false;
  int _queued = 0;

  static Future<Directory> _defaultDirectoryProvider() async => Directory(
    '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}logs',
  );

  static Future<void> _defaultDirectoryOpener(String path) async {
    if (BuildCapabilities.isMacAppStore) {
      await AppleVpnService.openLogs(path);
    } else if (Platform.isWindows) {
      await Process.start('explorer.exe', [
        path,
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.start('open', [path], mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
    } else {
      throw UnsupportedError(appStrings.logFoldersAreOnlyAvailableOnDesktop);
    }
  }

  Future<Directory> _initialize() => _directory ??= (() async {
    try {
      final directory = await _directoryProvider();
      await _backend.configure(directory.path);
      _ready = true;
      return directory;
    } catch (_) {
      _directory = null;
      rethrow;
    }
  })();

  Future<void> initialize() async {
    if (enabled && _disposed == null) await _initialize();
  }

  Future<void> write(LogEntry entry) {
    if (!enabled || _disposed != null || entry.persisted) {
      return Future<void>.value();
    }
    if (_ready && _queued == 0) {
      _backend.write(entry);
      return Future<void>.value();
    }
    _queued++;
    final write = _pending.then((_) async {
      try {
        await _initialize();
        _backend.write(entry);
      } finally {
        _queued--;
      }
    });
    _pending = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  Future<void> openLogDirectory() async {
    if (!enabled) {
      throw UnsupportedError(appStrings.logFoldersAreOnlyAvailableOnDesktop);
    }
    await _directoryOpener((await _initialize()).path);
  }

  Future<void> dispose() => _disposed ??= (() async {
    if (!enabled) return;
    await _pending;
    if (_directory != null) await _directory;
    if (_ready) await _backend.flush();
  })();
}
