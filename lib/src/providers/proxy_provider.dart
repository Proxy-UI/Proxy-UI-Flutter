import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ffi/proxy_ffi.dart';
import '../ffi/proxy_service.dart';
import '../models/node_catalog_preferences.dart';
import '../models/node_group_model.dart';
import '../models/node_model.dart';
import '../models/proxy_config.dart';
import '../services/desktop_log_service.dart';
import '../services/node_latency_service.dart';
import '../services/subscription_service.dart';

/// Proxy state provider for UI.
class ProxyState extends ChangeNotifier {
  final ProxyService _service;
  final DesktopLogService _desktopLogService;
  ProxyConfigModel _config = ProxyConfigModel();
  bool _isRunning = false;
  bool _isTunRunning = false;
  bool _isTunBusy = false;
  String? _lastError;
  final List<LogEntry> _logs = [];
  StreamSubscription<LogEntry>? _logSubscription;
  int _minLogLevel = 0; // 0=trace, 1=debug, 2=info, 3=warn, 4=error

  // Subscription service
  SubscriptionService? _subscriptionService;
  bool _subscriptionServiceRunning = false;
  int _subscriptionServicePort = 8080;
  String? _clashUrl;
  String? _shadowrocketUrl;

  // Node management
  List<NodeInfo> _nodes = [];
  bool _isLoadingNodes = false;
  String? _nodesError;
  String? _currentNodeId; // Track which node is currently connected
  List<NodeGroupModel> _groups = [];
  String? _groupsError;

  // Independent node server config
  NodeCatalogPreferences _nodeCatalogPreferences =
      const NodeCatalogPreferences();
  Timer? _nodeCatalogSaveTimer;
  bool _isInitialized = false;

  static const int maxLogs = 1000;
  static const String _configKey = 'proxy_config';
  static const String _nodeCatalogPreferencesKey = 'node_catalog_preferences';
  static const String _legacyNodesServerConfigKey = 'nodes_server_config';
  static const String _legacyNodeLatenciesKey = 'node_latencies';
  final bool _enableTunOnStartup;

  ProxyState({
    bool enableTunOnStartup = false,
    ProxyService? service,
    DesktopLogService? desktopLogService,
  }) : _enableTunOnStartup = enableTunOnStartup,
       _service = service ?? ProxyService(),
       _desktopLogService = desktopLogService ?? DesktopLogService() {
    _init();
  }

  ProxyConfigModel get config => _config;
  bool get isRunning => _isRunning;
  bool get isTunRunning => _isTunRunning;
  bool get isTunBusy => _isTunBusy;
  String? get lastError => _lastError;
  List<LogEntry> get logs => List.unmodifiable(_logs);
  int get minLogLevel => _minLogLevel;
  List<LogEntry> get filteredLogs =>
      _logs.where((e) => e.level >= _minLogLevel).toList();

  // Subscription service getters
  bool get subscriptionServiceRunning => _subscriptionServiceRunning;
  int get subscriptionServicePort => _subscriptionServicePort;
  String? get clashUrl => _clashUrl;
  String? get shadowrocketUrl => _shadowrocketUrl;

  // Node management getters
  List<NodeInfo> get nodes => _nodes;
  bool get isLoadingNodes => _isLoadingNodes;
  String? get nodesError => _nodesError;
  String? get currentNodeId => _currentNodeId;
  List<NodeGroupModel> get groups => _groups;
  String? get groupsError => _groupsError;
  String get nodesServerHost => _nodeCatalogPreferences.serverHost;
  int get nodesServerPort => _nodeCatalogPreferences.serverPort;
  String? get nodesSessionKey => _nodeCatalogPreferences.sessionKey;
  bool get sortNodesByLatency => _nodeCatalogPreferences.sortByLatency;
  bool get isInitialized => _isInitialized;
  bool get hasLocalLogStorage => _desktopLogService.enabled;

  Future<void> _init() async {
    _service.initLogging();
    _logSubscription = ProxyService.logStream.listen(_onLog);
    try {
      await _loadConfig();
    } finally {
      _isInitialized = true;
      notifyListeners();
    }
  }

  void _onLog(LogEntry entry) {
    _logs.add(entry);
    unawaited(_persistLog(entry));
    if (_logs.length > maxLogs) {
      _logs.removeAt(0);
    }
    // Native TUN setup failures cancel the shared listener token. Reconcile
    // the provider on the following native log instead of leaving the switch
    // in a connected state after the worker has stopped.
    if (_isRunning && !_service.isRunning) {
      _isRunning = false;
      _isTunRunning = false;
    } else if (_isTunRunning && !_isTunBusy && !_service.isTunRunning) {
      _isTunRunning = false;
      _config = _config.copyWith(tunEnabled: false);
      unawaited(_saveConfig());
    }
    notifyListeners();
  }

  Future<void> _persistLog(LogEntry entry) async {
    try {
      await _desktopLogService.write(entry);
    } on FileSystemException catch (error) {
      debugPrint('Failed to persist desktop log: ${error.message}');
    } catch (error) {
      debugPrint('Failed to persist desktop log: $error');
    }
  }

  Future<void> openLogDirectory() => _desktopLogService.openLogDirectory();

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final configJson = prefs.getString(_configKey);
    if (configJson != null) {
      try {
        _config = ProxyConfigModel.fromJson(jsonDecode(configJson));
        if (!_enableTunOnStartup && _config.tunEnabled) {
          // TUN changes system routes and is intentionally not restored after a
          // normal app launch. It must be enabled explicitly for each session.
          _config = _config.copyWith(tunEnabled: false);
          await _saveConfig();
        }
        notifyListeners();
      } catch (_) {
        // Ignore invalid config
      }
    }
    final nodeCatalogJson = prefs.getString(_nodeCatalogPreferencesKey);
    var nodeCatalogLoaded = false;
    if (nodeCatalogJson != null) {
      try {
        _nodeCatalogPreferences = NodeCatalogPreferences.fromJson(
          jsonDecode(nodeCatalogJson) as Map<String, dynamic>,
        );
        nodeCatalogLoaded = true;
      } catch (_) {
        // Ignore damaged UI preferences and retain safe defaults.
      }
    }
    if (!nodeCatalogLoaded) {
      final legacyServerJson = prefs.getString(_legacyNodesServerConfigKey);
      final legacyLatenciesJson = prefs.getString(_legacyNodeLatenciesKey);
      if (legacyServerJson != null || legacyLatenciesJson != null) {
        try {
          _nodeCatalogPreferences = NodeCatalogPreferences.fromLegacyJson(
            server: legacyServerJson == null
                ? const {}
                : jsonDecode(legacyServerJson) as Map<String, dynamic>,
            latencies: legacyLatenciesJson == null
                ? const {}
                : jsonDecode(legacyLatenciesJson) as Map<String, dynamic>,
          );
          await _saveNodeCatalogPreferences();
        } catch (_) {
          // Ignore damaged legacy preferences and retain safe defaults.
        }
      }
    }
    if (_enableTunOnStartup) {
      unawaited(_resumeElevatedTun());
    }
  }

  Future<void> _resumeElevatedTun() async {
    // The unelevated instance releases the local port immediately after it
    // launches this process. Retry briefly so the handoff never reports a
    // false bind failure while the old listener is shutting down.
    for (var attempt = 0; attempt < 20 && !_isRunning; attempt++) {
      if (await start()) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!_isRunning) return;
    await setTunEnabled(true);
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configKey, jsonEncode(_config.toJson()));
  }

  Future<void> _saveNodeCatalogPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString(
        _nodeCatalogPreferencesKey,
        jsonEncode(_nodeCatalogPreferences.toJson()),
      ),
      prefs.setString(
        _legacyNodesServerConfigKey,
        jsonEncode({
          'host': _nodeCatalogPreferences.serverHost,
          'port': _nodeCatalogPreferences.serverPort,
          'sessionKey': _nodeCatalogPreferences.sessionKey,
        }),
      ),
      prefs.setString(
        _legacyNodeLatenciesKey,
        jsonEncode(_nodeCatalogPreferences.legacyLatencies),
      ),
    ]);
  }

  void _scheduleNodeCatalogSave() {
    _nodeCatalogSaveTimer?.cancel();
    _nodeCatalogSaveTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_saveNodeCatalogPreferences()),
    );
  }

  void updateConfig(ProxyConfigModel config) {
    _config = config;
    _saveConfig();
    notifyListeners();
  }

  Future<bool> start() async {
    if (_isTunBusy) {
      _lastError = 'Wait for TUN setup to finish';
      notifyListeners();
      return false;
    }
    // Stop first if already running to apply new config
    if (_isRunning) {
      stop();
    }
    if (_config.serverHost.isEmpty) {
      _lastError = 'Server host is required';
      notifyListeners();
      return false;
    }

    _lastError = null;
    final result = await _service.start(
      serverHost: _config.serverHost,
      serverPort: _config.serverPort,
      localPort: _config.localPort,
      sessionKey: _config.sessionKey,
      autoProxy: _config.autoProxy,
      udpEnabled: _config.udpEnabled,
      // UI TUN has an independent lifecycle and starts only after this call
      // proves that the local HTTP/SOCKS5 port is listening.
      tunEnabled: false,
      tunBypassProcesses: _config.tunBypassProcesses,
      reverseGeo: _config.reverseGeo,
      needCodecIps: _config.needCodecIps,
      forceCodec: _config.forceCodec,
      setSystemProxy: _config.setSystemProxy,
    );

    if (result == ProxyResult.ok) {
      _isRunning = true;
      notifyListeners();
      return true;
    } else {
      _lastError = ProxyResult.message(result);
      notifyListeners();
      return false;
    }
  }

  /// Retrieve process candidates and the executable that native code protects
  /// from removal. Process enumeration is only exposed by the Windows UI.
  ({List<TunProcessInfo> processes, String? selfProcess})
  getTunProcessOptions() {
    return (
      processes: _service.listTunProcessDetails(),
      selfProcess: _service.tunSelfProcess,
    );
  }

  /// Persist and, when TUN is active, immediately apply process exclusions.
  Future<bool> updateTunBypassProcesses(List<String> processes) async {
    if (_isRunning && _isTunRunning) {
      final result = _service.setTunBypassProcesses(processes);
      if (result != ProxyResult.ok) {
        _lastError = _service.lastError ?? ProxyResult.message(result);
        notifyListeners();
        return false;
      }
    }
    _config = _config.copyWith(tunBypassProcesses: processes);
    await _saveConfig();
    notifyListeners();
    return true;
  }

  /// Enable or disable TUN without tearing down the local proxy listener.
  ///
  /// Returns `null` when an unelevated Windows instance successfully launched
  /// its elevated replacement. The caller should then close the old window.
  Future<bool?> setTunEnabled(bool enabled) async {
    if (_isTunBusy) return false;
    if (enabled == _isTunRunning) return true;
    if (enabled && !_isRunning) {
      _lastError = 'Start the local proxy before enabling TUN mode';
      notifyListeners();
      return false;
    }

    _isTunBusy = true;
    _lastError = null;
    notifyListeners();
    try {
      if (enabled && Platform.isWindows && !_service.isElevated) {
        _config = _config.copyWith(tunEnabled: true);
        await _saveConfig();
        final result = _service.relaunchElevatedForTun();
        if (result == ProxyResult.ok) {
          return null;
        }
        _config = _config.copyWith(tunEnabled: false);
        await _saveConfig();
        _lastError =
            'Administrator permission was not granted. TUN mode was not changed.';
        return false;
      }

      final result = enabled
          ? await _service.startTun(_config.tunBypassProcesses)
          : await _service.stopTun();
      if (result != ProxyResult.ok &&
          !(result == ProxyResult.notRunning && !enabled)) {
        _lastError = _service.lastError ?? ProxyResult.message(result);
        return false;
      }
      _isTunRunning = enabled;
      _config = _config.copyWith(tunEnabled: enabled);
      await _saveConfig();
      return true;
    } finally {
      _isTunBusy = false;
      notifyListeners();
    }
  }

  /// Release the local port after the elevated replacement has been accepted.
  /// Keep `tunEnabled` persisted so the new process knows to complete TUN setup.
  void stopForElevationHandoff() {
    if (_isRunning) {
      _service.stop();
    }
    _isRunning = false;
    _isTunRunning = false;
    notifyListeners();
  }

  bool stop() {
    if (_isTunBusy) return false;
    if (!_isRunning) return true;

    // `proxy_stop` cancels the TUN child token before the local listener token,
    // so no separate blocking FFI call is needed on whole-proxy shutdown.
    final result = _service.stop();
    if (result == ProxyResult.ok || result == ProxyResult.notRunning) {
      _isRunning = false;
      _isTunRunning = false;
      _config = _config.copyWith(tunEnabled: false);
      unawaited(_saveConfig());
      notifyListeners();
      return true;
    } else {
      _lastError = ProxyResult.message(result);
      notifyListeners();
      return false;
    }
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  void setMinLogLevel(int level) {
    _minLogLevel = level.clamp(0, 4);
    notifyListeners();
  }

  Future<void> startSubscriptionService({int port = 8080}) async {
    if (_subscriptionServiceRunning) return;

    _subscriptionService = SubscriptionService();
    await _subscriptionService!.start(_config, port);
    _subscriptionServiceRunning = true;
    _subscriptionServicePort = port;
    _clashUrl = await _subscriptionService!.getClashUrl();
    _shadowrocketUrl = await _subscriptionService!.getShadowrocketUrl();
    notifyListeners();
  }

  Future<void> stopSubscriptionService() async {
    await _subscriptionService?.stop();
    _subscriptionService = null;
    _subscriptionServiceRunning = false;
    _clashUrl = null;
    _shadowrocketUrl = null;
    notifyListeners();
  }

  // Check if a node is the current one
  bool isCurrentNode(NodeInfo node) {
    return _currentNodeId == node.nodeId &&
        _config.serverHost == node.host &&
        _config.serverPort == node.port;
  }

  // Update nodes server config
  void updateNodesServerConfig({String? host, int? port, String? sessionKey}) {
    _nodeCatalogPreferences = _nodeCatalogPreferences.copyWith(
      serverHost: host,
      serverPort: port,
      sessionKey: sessionKey,
    );
    _scheduleNodeCatalogSave();
    notifyListeners();
  }

  void setSortNodesByLatency(bool enabled) {
    if (_nodeCatalogPreferences.sortByLatency == enabled) return;
    _nodeCatalogPreferences = _nodeCatalogPreferences.copyWith(
      sortByLatency: enabled,
    );
    _scheduleNodeCatalogSave();
    notifyListeners();
  }

  // Fetch nodes from server
  Future<void> fetchNodes() async {
    if (nodesServerHost.isEmpty) {
      _nodesError = 'Please enter server host';
      notifyListeners();
      return;
    }

    _nodeCatalogSaveTimer?.cancel();
    await _saveNodeCatalogPreferences();

    _isLoadingNodes = true;
    _nodesError = null;
    _groupsError = null;
    notifyListeners();

    try {
      final nodesFuture = _service.getServerNodes(
        serverHost: nodesServerHost,
        serverPort: nodesServerPort,
        sessionKey: nodesSessionKey?.isEmpty ?? true ? null : nodesSessionKey,
      );

      final groupsFuture = _service.getServerGroups(
        serverHost: nodesServerHost,
        serverPort: nodesServerPort,
        sessionKey: nodesSessionKey?.isEmpty ?? true ? null : nodesSessionKey,
      );

      try {
        _nodes = await nodesFuture;
        for (final node in _nodes) {
          node.latencyMs = _nodeCatalogPreferences.latencyFor(node);
        }
        _nodesError = null;
      } catch (e) {
        _nodesError = e.toString();
        _nodes = [];
      }

      try {
        _groups = await groupsFuture;
        _groupsError = null;
      } catch (e) {
        _groupsError = e.toString();
        _groups = [];
      }
    } finally {
      _isLoadingNodes = false;
      notifyListeners();
    }
  }

  /// Measure a node's TCP handshake latency without changing the active proxy.
  Future<int> pingNode(NodeInfo node) async {
    final latency = await measureNodeTcpLatency(
      host: node.host,
      port: node.port,
    );
    node.latencyMs = latency;
    _nodeCatalogPreferences = _nodeCatalogPreferences.withLatency(
      node,
      latency,
    );
    await _saveNodeCatalogPreferences();
    notifyListeners();
    return latency;
  }

  // Export node config to clipboard (reuse existing export logic)
  Future<void> exportNodeConfig(NodeInfo node) async {
    // Generate config for this node, preserving current settings
    final nodeConfig = node.toProxyConfig(
      localPort: _config.localPort,
      sessionKey: _config.sessionKey,
      autoProxy: _config.autoProxy,
      udpEnabled: _config.udpEnabled,
      tunEnabled: _config.tunEnabled,
      tunBypassProcesses: _config.tunBypassProcesses,
      reverseGeo: _config.reverseGeo,
      needCodecIps: _config.needCodecIps,
      forceCodec: _config.forceCodec,
      setSystemProxy: _config.setSystemProxy,
    );

    final json = jsonEncode(nodeConfig.toJson());
    final encoded = base64Encode(utf8.encode(json));
    await Clipboard.setData(ClipboardData(text: encoded));
  }

  // Switch to a different node
  Future<bool> switchToNode(NodeInfo node) async {
    final newConfig = node.toProxyConfig(
      localPort: _config.localPort,
      sessionKey: _config.sessionKey,
      autoProxy: _config.autoProxy,
      udpEnabled: _config.udpEnabled,
      tunEnabled: _isTunRunning,
      tunBypassProcesses: _config.tunBypassProcesses,
      reverseGeo: _config.reverseGeo,
      needCodecIps: _config.needCodecIps,
      forceCodec: _config.forceCodec,
      setSystemProxy: _config.setSystemProxy,
    );

    if (_isRunning && _isTunRunning) {
      return _hotSwitchTunNode(node, newConfig);
    }

    await _ensureNodeReachable(node);

    // Outside TUN mode, preserve the established restart behavior because
    // non-TUN HTTP/SOCKS sessions are not owned by the TUN relay and therefore
    // cannot all be drained by stopping capture.
    if (_isRunning) {
      if (!stop()) return false;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    updateConfig(newConfig);
    _currentNodeId = node.nodeId;

    // Start proxy with new config
    return await start();
  }

  Future<void> _ensureNodeReachable(NodeInfo node) async {
    try {
      final socket = await Socket.connect(
        node.host,
        node.port,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
    } on SocketException catch (error) {
      throw Exception('Node unreachable: ${error.message}');
    } on TimeoutException {
      throw Exception('Node unreachable: connection timeout');
    }
  }

  /// Switch a running TUN session without releasing the local proxy port.
  ///
  /// TUN routes contain an explicit exception for the remote proxy address.
  /// The native API consequently requires this order: stop only capture,
  /// validate and atomically replace the upstream, then recreate capture with
  /// the new route exception. Any failure restores the previous endpoint and
  /// TUN policy before returning to the UI.
  Future<bool> _hotSwitchTunNode(
    NodeInfo node,
    ProxyConfigModel newConfig,
  ) async {
    if (_isTunBusy) {
      _lastError = 'Wait for the current TUN operation to finish';
      notifyListeners();
      return false;
    }

    final previousConfig = _config.copyWith(tunEnabled: true);
    _isTunBusy = true;
    _lastError = null;
    notifyListeners();

    try {
      final stopResult = await _service.stopTun();
      if (stopResult != ProxyResult.ok &&
          stopResult != ProxyResult.notRunning) {
        _lastError =
            _service.lastError ??
            'Failed to pause TUN for node switch: ${ProxyResult.message(stopResult)}';
        _isTunRunning = _service.isTunRunning;
        if (!_isTunRunning) {
          _config = _config.copyWith(tunEnabled: false);
          await _saveConfig();
        }
        return false;
      }

      // Validate after route cleanup. This also works on platforms where
      // process-based self bypass is unavailable and a new endpoint would
      // otherwise be captured by the still-active TUN route.
      try {
        await _ensureNodeReachable(node);
      } catch (error) {
        return await _restorePreviousTun(
          previousConfig,
          'Cannot switch to ${node.displayName}: $error.',
          endpointChanged: false,
        );
      }

      final switchResult = _service.switchUpstream(
        serverHost: newConfig.serverHost,
        serverPort: newConfig.serverPort,
      );
      if (switchResult != ProxyResult.ok) {
        return await _restorePreviousTun(
          previousConfig,
          _service.lastError ??
              'Failed to switch upstream: ${ProxyResult.message(switchResult)}.',
          endpointChanged: false,
        );
      }

      final startResult = await _service.startTun(newConfig.tunBypassProcesses);
      if (startResult != ProxyResult.ok) {
        final switchError =
            _service.lastError ??
            'Failed to restart TUN for ${node.displayName}: '
                '${ProxyResult.message(startResult)}.';
        return await _restorePreviousTun(
          previousConfig,
          switchError,
          endpointChanged: true,
        );
      }

      _config = newConfig.copyWith(tunEnabled: true);
      _currentNodeId = node.nodeId;
      _isTunRunning = true;
      await _saveConfig();
      return true;
    } finally {
      _isTunBusy = false;
      notifyListeners();
    }
  }

  Future<bool> _restorePreviousTun(
    ProxyConfigModel previousConfig,
    String failure, {
    required bool endpointChanged,
  }) async {
    String? rollbackError;
    if (endpointChanged) {
      final switchBackResult = _service.switchUpstream(
        serverHost: previousConfig.serverHost,
        serverPort: previousConfig.serverPort,
      );
      if (switchBackResult != ProxyResult.ok) {
        rollbackError =
            _service.lastError ??
            'upstream rollback returned '
                '${ProxyResult.message(switchBackResult)}';
      }
    }

    if (rollbackError == null) {
      final restoreResult = await _service.startTun(
        previousConfig.tunBypassProcesses,
      );
      if (restoreResult != ProxyResult.ok) {
        rollbackError =
            _service.lastError ?? ProxyResult.message(restoreResult);
      }
    }

    if (rollbackError == null) {
      _config = previousConfig.copyWith(tunEnabled: true);
      _isTunRunning = true;
      _lastError = '$failure Previous node and TUN routes were restored.';
    } else {
      _config = previousConfig.copyWith(tunEnabled: false);
      _isTunRunning = false;
      _lastError =
          '$failure Rollback could not restore TUN mode: $rollbackError. '
          'Traffic capture is now off.';
    }
    await _saveConfig();
    return false;
  }

  @override
  void dispose() {
    _nodeCatalogSaveTimer?.cancel();
    unawaited(_saveNodeCatalogPreferences());
    _logSubscription?.cancel();
    unawaited(_desktopLogService.dispose());
    _service.dispose();
    _subscriptionService?.stop();
    super.dispose();
  }
}
