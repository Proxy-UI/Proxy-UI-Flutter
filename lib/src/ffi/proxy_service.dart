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
import '../models/socks5_link.dart';
import '../services/android_vpn_service.dart';
import 'proxy_ffi.dart';
import 'native_operation_queue.dart';
import 'native_proxy_operations.dart';

/// Log entry from native library.
class LogEntry {
  final int level;
  final String message;
  final DateTime timestamp;
  final bool persisted;

  LogEntry({
    required this.level,
    required this.message,
    DateTime? timestamp,
    this.persisted = false,
  }) : timestamp = timestamp ?? DateTime.now();

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

/// A node to probe, by address.
typedef NodeProbeTarget = ({String host, int port});

/// A native probe batch still delivering results.
class _ProbeBatch {
  _ProbeBatch(this.results, this.remaining);

  final StreamController<(int, NodeProbe)> results;
  int remaining;
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
      _logController.add(LogEntry(level: level, message: msg, persisted: true));
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
    bool udpEnabled = false,
    bool udpDirectFallback = true,
    bool tunEnabled = false,
    bool tunFakeIp = false,
    String tunDnsServer = '223.5.5.5',
    List<String> tunBypassProcesses = const [],
    bool reverseGeo = false,
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

    final supportDir = await getApplicationSupportDirectory();
    return _nativeCode('start', _handle!, {
      'config': {
        'server_host': serverHost,
        'server_port': serverPort,
        'local_port': localPort,
        'session_key': sessionKey != null && sessionKey.length == 32
            ? sessionKey
            : null,
        'cache_directory': supportDir.path,
        'auto_proxy': autoProxy,
        'udp_enabled': udpEnabled,
        'udp_direct_fallback': udpDirectFallback,
        'tun_enabled': tunEnabled,
        'tun_fake_ip': tunFakeIp,
        'tun_dns_server': tunDnsServer,
        'tun_bypass_processes': tunBypassProcesses,
        'reverse_geo': reverseGeo,
        'secure_transport': secureTransport,
        'set_system_proxy':
            (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
            setSystemProxy,
        'allow_lan': allowLan,
      },
    });
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
  Future<List<TunProcessInfo>> listTunProcessDetails() async {
    final result = await NativeProxyOperations.shared.run('processes');
    return (result['processes'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map(TunProcessInfo.fromJson)
        .where((process) => process.name.isNotEmpty)
        .toList(growable: false);
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

  bool get supportsLiveTunSwitch => Platform.isWindows;

  static Future<int> _nativeCode(
    String operation,
    Pointer<Void> handle, [
    Map<String, Object?> arguments = const {},
  ]) async =>
      (await NativeProxyOperations.shared.run(
            operation,
            handle: handle,
            arguments: arguments,
          ))['code']
          as int;

  /// Windows prepares the physical bypass before atomically publishing the
  /// endpoint. Route/DNS waits must not run on the UI isolate or race teardown.
  Future<int> switchUpstream({
    required String serverHost,
    required int serverPort,
  }) => _withHandle(() async {
    if (_handle == null) return ProxyResult.notRunning;
    return _nativeCode('switch_upstream', _handle!, {
      'server_host': serverHost,
      'server_port': serverPort,
    });
  });

  /// Enable TUN only after the local proxy listener has started. Native setup
  /// can wait for adapter and route readiness, so it runs outside the UI isolate.
  Future<int> startTun(List<String> processes) => _withHandle(() async {
    if (_handle == null) return ProxyResult.notRunning;
    return _nativeCode('start_tun', _handle!, {'processes': processes});
  });

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
      final result = await _nativeCode('start_android_tun', handle, {
        'tun_fd': interface.fileDescriptor,
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
          await _nativeCode('stop_tun', handle);
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

  /// Stop TUN capture without stopping the local HTTP/SOCKS5 listener. Route
  /// cleanup can briefly block, so it also stays outside the UI isolate.
  Future<int> stopTun() => _withHandle(() async {
    if (_handle == null) return ProxyResult.notRunning;
    return _nativeCode('stop_tun', _handle!);
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

  /// Stop the proxy, and any TUN session it owns.
  ///
  /// Native code waits for TUN teardown to restore the system routes and DNS
  /// before returning, so this stays off the UI isolate for the same reason
  /// [stopTun] does.
  Future<int> stop() => _withHandle(() async {
    if (_handle == null) return ProxyResult.notRunning;
    await stopAndroidVpnInterface();
    return _nativeCode('stop', _handle!);
  });

  /// Destroy the handle after pending native operations have finished.
  Future<void> destroy() => _withHandle(_destroyHandle);

  Future<void> _destroyHandle() async {
    final handle = _handle;
    _handle = null;
    _runningSnapshot = false;
    _tunSnapshot = false;
    if (handle != null && handle != nullptr) {
      try {
        await _nativeCode('destroy', handle);
      } on NativeOperationRejected {
        // Rejection occurs before Rust takes ownership. Retain it for retry.
        _handle = handle;
        rethrow;
      }
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
            // The queue retains the pointer until every native operation has returned.
            try {
              await stopAndroidVpnInterface();
              await _nativeCode('stop', handle);
            } finally {
              await _destroyHandle();
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            debugPrint('Native proxy cleanup failed: $error\n$stackTrace');
          }),
    );
  }

  /// Test proxy latency (only works when proxy is running).
  /// Tests real-world latency by sending HTTPS request through local proxy.
  Future<int?> testLatency({String? testUrl, int timeoutMs = 10000}) =>
      _withHandle(() async {
        if (_handle == null) throw StateError(appStrings.proxyNotInitialized);

        final result = await NativeProxyOperations.shared.run(
          'latency',
          handle: _handle,
          arguments: {'test_url': testUrl, 'timeout_ms': timeoutMs},
        );

        if (result['success'] == true) {
          return result['latencyMs'] as int;
        } else {
          throw Exception(result['error'] ?? appStrings.latencyTestFailed);
        }
      });

  static int _wireProtocol(bool secureTransport) => secureTransport ? 3 : 0;

  static Map<String, dynamic> _readProbe(NodeProbeResult result) {
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
  }

  static NodeProbe _nodeProbe(Map<String, dynamic> result) {
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

  /// Verifies a node's real egress country.
  Future<NodeProbe> probeNode({
    required String serverHost,
    required int serverPort,
    bool secureTransport = false,
    int timeoutMs = 10000,
  }) async {
    final batch = _batchProbe;
    if (batch == null) {
      throw UnsupportedError('Native probe batch is unavailable');
    }
    final results = StreamController<(int, NodeProbe)>();
    _startBatch(
      batch,
      [(host: serverHost, port: serverPort)],
      results,
      secureTransport: secureTransport,
      timeoutMs: timeoutMs,
    );
    return (await results.stream.first).$2;
  }

  /// Probes run together by the native batch. Each is a socket and a task on
  /// one shared runtime, so this bounds the burst through the upstream rather
  /// than threads.
  static const int batchProbeConcurrency = 16;

  /// Probes run together one isolate each, on a native library without the
  /// batch. Each holds a blocked thread for as long as its node takes.
  static const int isolateProbeConcurrency = 8;

  /// Probes [targets] together and reports each as `(index, probe)` when it
  /// finishes, in completion order. The stream closes after the last one.
  ///
  /// The native batch runs every probe on the shared runtime and posts each
  /// result back as a message. Probing node by node instead costs an isolate
  /// and a blocked thread per node, for the whole timeout of a dead one; that
  /// path remains for native libraries that predate the batch.
  Stream<(int, NodeProbe)> probeNodes(
    List<NodeProbeTarget> targets, {
    bool secureTransport = false,
    int timeoutMs = 10000,
  }) {
    final batch = _batchProbe;
    if (batch == null) {
      return _probeEach(
        targets,
        secureTransport: secureTransport,
        timeoutMs: timeoutMs,
      );
    }
    late final StreamController<(int, NodeProbe)> results;
    results = StreamController(
      onListen: () => _startBatch(
        batch,
        targets,
        results,
        secureTransport: secureTransport,
        timeoutMs: timeoutMs,
      ),
    );
    return results.stream;
  }

  Stream<(int, NodeProbe)> _probeEach(
    List<NodeProbeTarget> targets, {
    required bool secureTransport,
    required int timeoutMs,
  }) {
    late final StreamController<(int, NodeProbe)> results;
    results = StreamController(
      onListen: () {
        var next = 0;
        Future<void> worker() async {
          while (next < targets.length) {
            final index = next++;
            final target = targets[index];
            NodeProbe probe;
            try {
              probe = await probeNode(
                serverHost: target.host,
                serverPort: target.port,
                secureTransport: secureTransport,
                timeoutMs: timeoutMs,
              );
            } catch (error) {
              probe = NodeProbe(success: false, error: error.toString());
            }
            results.add((index, probe));
          }
        }

        final workers = targets.length < isolateProbeConcurrency
            ? targets.length
            : isolateProbeConcurrency;
        Future.wait([for (var i = 0; i < workers; i++) worker()])
            .whenComplete(results.close);
      },
    );
    return results.stream;
  }

  static final ProxyProbeNodesDart? _batchProbe = () {
    try {
      return ProxyFFI().proxyProbeNodes;
    } catch (_) {
      // No native library at all, as under unit tests.
      return null;
    }
  }();

  /// Batches awaiting results, by the id handed to native code.
  static final Map<int, _ProbeBatch> _probeBatches = {};
  static int _lastProbeBatch = 0;

  /// One callback for every batch, kept for the isolate's lifetime like the
  /// log callback: native code may still deliver into it after its batch's
  /// listener has gone away.
  static NativeCallable<NodeProbeCallbackNative>? _probeCallback;

  static void _startBatch(
    ProxyProbeNodesDart start,
    List<NodeProbeTarget> targets,
    StreamController<(int, NodeProbe)> results, {
    required bool secureTransport,
    required int timeoutMs,
  }) {
    if (targets.isEmpty) {
      results.close();
      return;
    }
    final id = ++_lastProbeBatch;
    _probeBatches[id] = _ProbeBatch(results, targets.length);
    final callback = _probeCallback ??=
        NativeCallable<NodeProbeCallbackNative>.listener(_onProbeResult)
          ..keepIsolateAlive = false;
    final hosts = calloc<Pointer<Utf8>>(targets.length);
    final ports = calloc<Uint16>(targets.length);
    try {
      for (var i = 0; i < targets.length; i++) {
        hosts[i] = targets[i].host.toNativeUtf8();
        ports[i] = targets[i].port;
      }
      final code = start(
        hosts,
        ports,
        targets.length,
        batchProbeConcurrency,
        timeoutMs,
        _wireProtocol(secureTransport),
        callback.nativeFunction,
        id,
      );
      if (code != ProxyResult.ok) {
        _probeBatches.remove(id);
        results
          ..addError(StateError(ProxyResult.message(code)))
          ..close();
      }
    } finally {
      // Native code copied everything it needs before returning.
      for (var i = 0; i < targets.length; i++) {
        if (hosts[i] != nullptr) calloc.free(hosts[i]);
      }
      calloc
        ..free(hosts)
        ..free(ports);
    }
  }

  static void _onProbeResult(
    int batch,
    int index,
    Pointer<NodeProbeResult> result,
  ) {
    final Map<String, dynamic> fields;
    try {
      fields = _readProbe(result.ref);
    } finally {
      ProxyFFI().proxyReleaseNodeProbeResult(result);
    }
    final pending = _probeBatches[batch];
    if (pending == null) return;
    pending.results.add((index, _nodeProbe(fields)));
    if (--pending.remaining == 0) {
      _probeBatches.remove(batch);
      pending.results.close();
    }
  }

  /// Get all nodes from server with geo location info.
  Future<List<NodeInfo>> getServerNodes({
    required String serverHost,
    required int serverPort,
    String? sessionKey,
    int timeoutMs = 10000,
  }) async {
    final result = await NativeProxyOperations.shared.run(
      'nodes',
      arguments: {
        'server_host': serverHost,
        'server_port': serverPort,
        'session_key': sessionKey,
        'timeout_ms': timeoutMs,
      },
    );

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

  /// The node's SOCKS5 link, or null when it serves none. Throws when the
  /// node, or the native library, cannot answer.
  Future<Socks5Link?> getSocks5Link({
    required String serverHost,
    required int serverPort,
    String? sessionKey,
    int timeoutMs = 5000,
  }) async {
    final result = await NativeProxyOperations.shared.run(
      'socks5_endpoint',
      arguments: {
        'server_host': serverHost,
        'server_port': serverPort,
        'session_key': sessionKey,
        'timeout_ms': timeoutMs,
      },
    );
    return Socks5Link.fromJson(result);
  }

  /// Get all node groups from server.
  Future<List<NodeGroupModel>> getServerGroups({
    required String serverHost,
    required int serverPort,
    String? sessionKey,
    int timeoutMs = 10000,
  }) async {
    final result = await NativeProxyOperations.shared.run(
      'groups',
      arguments: {
        'server_host': serverHost,
        'server_port': serverPort,
        'session_key': sessionKey,
        'timeout_ms': timeoutMs,
      },
    );

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
