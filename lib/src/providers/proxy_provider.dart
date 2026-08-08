import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

import '../ffi/proxy_ffi.dart';
import '../ffi/proxy_service.dart';
import '../models/node_catalog_preferences.dart';
import '../models/node_group_model.dart';
import '../models/node_model.dart';
import '../models/proxy_config.dart';
import '../services/desktop_log_service.dart';
import '../services/android_vpn_service.dart';
import '../services/node_latency_service.dart';
import '../services/subscription_service.dart';

/// Proxy state provider for UI.
class ProxyState extends ChangeNotifier {
  final ProxyService _service;
  final DesktopLogService _desktopLogService;
  ProxyConfigModel _config = ProxyConfigModel();
  bool _isRunning = false;
  bool _isProxyTransitioning = false;
  bool _isTunRunning = false;
  bool _isTunBusy = false;
  String? _lastError;
  final ListQueue<LogEntry> _logs = ListQueue<LogEntry>();
  StreamSubscription<LogEntry>? _logSubscription;
  Timer? _logNotificationTimer;
  int _minLogLevel = ProxyService.defaultLogLevel;

  // Subscription service
  SubscriptionService? _subscriptionService;
  bool _subscriptionServiceRunning = false;
  bool _subscriptionServiceBusy = false;
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
  // Supersedes the earlier flat host/port/key fields; the loader below still
  // migrates those legacy preference keys.
  NodeCatalogPreferences _nodeCatalogPreferences =
      const NodeCatalogPreferences();
  Timer? _nodeCatalogSaveTimer;
  bool _isInitialized = false;
  bool _isDisposed = false;

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
  bool get isProxyOperationInProgress => _isProxyTransitioning;
  bool get isTunRunning => _isTunRunning;
  bool get isTunBusy => _isTunBusy;
  String? get lastError => _lastError;
  List<LogEntry> get logs => List.unmodifiable(_logs);
  int get minLogLevel => _minLogLevel;
  List<LogEntry> get filteredLogs => _logs
      .where(
        (e) => LogLevel.includes(threshold: _minLogLevel, entryLevel: e.level),
      )
      .toList();

  // Subscription service getters
  bool get subscriptionServiceRunning => _subscriptionServiceRunning;
  bool get subscriptionServiceBusy => _subscriptionServiceBusy;
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

  void _safeNotifyListeners() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  Future<void> _init() async {
    _service.initLogging();
    _logSubscription = ProxyService.logStream.listen(_onLog);
    // Must run before anything can take the system proxy over again, so the
    // settings captured below are the user's own and not a dead run's.
    _service.restoreOrphanedSystemProxy();
    try {
      await _loadConfig();
    } catch (error, stackTrace) {
      debugPrint('ProxyState init failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      // The UI waits on this flag, so it has to be set even when loading threw.
      _isInitialized = true;
      _safeNotifyListeners();
    }
  }

  void _onLog(LogEntry entry) {
    _logs.addLast(entry);
    unawaited(_persistLog(entry));
    if (_logs.length > maxLogs) {
      _logs.removeFirst();
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
      if (Platform.isAndroid) {
        unawaited(_service.stopAndroidVpnInterface());
      }
      unawaited(_saveConfig());
    }
    // Native traffic can produce hundreds of useful session logs per second.
    // Rebuild the log page at a human-visible cadence instead of once per
    // entry, which would compete with forwarding and game render threads.
    _logNotificationTimer ??= Timer(const Duration(milliseconds: 100), () {
      _logNotificationTimer = null;
      _safeNotifyListeners();
    });
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

  /// Drains the pending log queue to disk.
  ///
  /// The tray quit and the TUN elevation handoff both end in `exit`, which
  /// skips Dart finalizers; without this the buffered entries that explain why
  /// the app was shutting down are exactly the ones that get lost.
  Future<void> flushDesktopLogs() => _desktopLogService.dispose();

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
        _safeNotifyListeners();
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
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_configKey, jsonEncode(_config.toJson()));
    } catch (error, stackTrace) {
      debugPrint('Failed to persist proxy config: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
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
    unawaited(_saveConfig());
    _safeNotifyListeners();
  }

  bool _isValidPort(int port) => port >= 1 && port <= 65535;

  Future<bool> start() async {
    if (_isProxyTransitioning) {
      _lastError = 'Proxy operation is already in progress';
      _safeNotifyListeners();
      return false;
    }
    if (_isTunBusy) {
      _lastError = 'Wait for TUN setup to finish';
      _safeNotifyListeners();
      return false;
    }

    // Stop first if already running to apply new config
    if (_isRunning) {
      if (!stop()) {
        return false;
      }
    }

    _isProxyTransitioning = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      if (_config.serverHost.isEmpty) {
        _lastError = 'Server host is required';
        return false;
      }
      if (!_isValidPort(_config.serverPort)) {
        _lastError = 'Server port must be between 1 and 65535';
        return false;
      }
      if (!_isValidPort(_config.localPort)) {
        _lastError = 'Local port must be between 1 and 65535';
        return false;
      }

      final result = await _service.start(
        serverHost: _config.serverHost,
        serverPort: _config.serverPort,
        localPort: _config.localPort,
        allowLan: _config.allowLan,
        sessionKey: _config.sessionKey,
        autoProxy: _config.autoProxy,
        udpEnabled: _config.udpEnabled,
        udpDirectFallback: _config.udpDirectFallback,
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
        return true;
      }

      _lastError = ProxyResult.message(result);
      return false;
    } catch (error) {
      _lastError = 'Failed to start proxy: $error';
      return false;
    } finally {
      _isProxyTransitioning = false;
      _safeNotifyListeners();
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

  Future<List<AndroidVpnApplication>> listAndroidVpnApplications({
    bool forceRefresh = false,
  }) {
    return _service.listAndroidVpnApplications(forceRefresh: forceRefresh);
  }

  /// Persist Android's package policy. An active VPN interface must be
  /// recreated because VpnService application rules are immutable after
  /// `Builder.establish()`.
  Future<bool> updateAndroidVpnPolicy(
    AndroidVpnRoutingMode mode,
    List<String> packages,
  ) async {
    if (!Platform.isAndroid) return false;
    if (mode == AndroidVpnRoutingMode.include && packages.isEmpty) {
      _lastError = 'Select at least one application for VPN-only mode';
      notifyListeners();
      return false;
    }

    final previous = _config;
    final updated = _config.copyWith(
      androidVpnRoutingMode: mode,
      androidVpnPackages: packages,
    );
    if (!_isTunRunning) {
      _config = updated;
      await _saveConfig();
      notifyListeners();
      return true;
    }
    if (_isTunBusy) return false;

    _isTunBusy = true;
    _lastError = null;
    notifyListeners();
    try {
      final stopResult = await _stopConfiguredTun();
      if (stopResult != ProxyResult.ok &&
          stopResult != ProxyResult.notRunning) {
        _lastError = _service.lastError ?? ProxyResult.message(stopResult);
        return false;
      }

      _config = updated;
      final startResult = await _startConfiguredTun();
      if (startResult == ProxyResult.ok) {
        _isTunRunning = true;
        _config = updated.copyWith(tunEnabled: true);
        await _saveConfig();
        return true;
      }

      final updateError =
          _service.lastError ?? ProxyResult.message(startResult);
      _config = previous;
      final restoreResult = await _startConfiguredTun();
      if (restoreResult == ProxyResult.ok) {
        _isTunRunning = true;
        _lastError = '$updateError Previous application policy was restored.';
      } else {
        _isTunRunning = false;
        _config = previous.copyWith(tunEnabled: false);
        _lastError =
            '$updateError Previous application policy could not be restored: '
            '${_service.lastError ?? ProxyResult.message(restoreResult)}';
      }
      await _saveConfig();
      return false;
    } finally {
      _isTunBusy = false;
      notifyListeners();
    }
  }

  Future<int> _startConfiguredTun() {
    if (Platform.isAndroid) {
      return _service.startAndroidTun(
        mode: _config.androidVpnRoutingMode.wireName,
        packages: _config.androidVpnPackages,
      );
    }
    return _service.startTun(_config.tunBypassProcesses);
  }

  Future<int> _stopConfiguredTun() {
    return Platform.isAndroid ? _service.stopAndroidTun() : _service.stopTun();
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
          ? await _startConfiguredTun()
          : await _stopConfiguredTun();
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
    if (_isProxyTransitioning) {
      _lastError = 'Proxy operation is already in progress';
      _safeNotifyListeners();
      return false;
    }
    if (_isTunBusy) return false;
    if (!_isRunning) return true;

    _isProxyTransitioning = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      // `proxy_stop` cancels the TUN child token before the local listener
      // token, so no separate blocking FFI call is needed on whole-proxy
      // shutdown.
      final result = _service.stop();
      if (result == ProxyResult.ok || result == ProxyResult.notRunning) {
        _isRunning = false;
        _isTunRunning = false;
        _config = _config.copyWith(tunEnabled: false);
        unawaited(_saveConfig());
        return true;
      } else {
        _lastError = ProxyResult.message(result);
        return false;
      }
    } finally {
      _isProxyTransitioning = false;
      _safeNotifyListeners();
    }
  }

  void clearLogs() {
    _logs.clear();
    _safeNotifyListeners();
  }

  void setMinLogLevel(int level) {
    _minLogLevel = LogLevel.normalize(level);
    // Also raise the native floor so the levels the UI filters out are never
    // shipped across the FFI boundary in the first place.
    _service.setLogLevel(_minLogLevel);
    _safeNotifyListeners();
  }

  Future<void> startSubscriptionService({int port = 8080}) async {
    if (_subscriptionServiceRunning || _subscriptionServiceBusy) return;
    if (!_isValidPort(port)) {
      throw ArgumentError.value(
        port,
        'port',
        'Port must be between 1 and 65535',
      );
    }

    _subscriptionServiceBusy = true;
    _safeNotifyListeners();

    _subscriptionService = SubscriptionService();
    try {
      await _subscriptionService!.start(_config, port);
      _subscriptionServiceRunning = true;
      _subscriptionServicePort = port;
      _clashUrl = await _subscriptionService!.getClashUrl();
      _shadowrocketUrl = await _subscriptionService!.getShadowrocketUrl();
    } catch (_) {
      _subscriptionService = null;
      _subscriptionServiceRunning = false;
      _clashUrl = null;
      _shadowrocketUrl = null;
      rethrow;
    } finally {
      _subscriptionServiceBusy = false;
      _safeNotifyListeners();
    }
  }

  Future<void> stopSubscriptionService() async {
    if (_subscriptionServiceBusy) return;

    _subscriptionServiceBusy = true;
    _safeNotifyListeners();

    try {
      await _subscriptionService?.stop();
      _subscriptionService = null;
      _subscriptionServiceRunning = false;
      _clashUrl = null;
      _shadowrocketUrl = null;
    } finally {
      _subscriptionServiceBusy = false;
      _safeNotifyListeners();
    }
  }

  // Check if a node is the current one
  bool isCurrentNode(NodeInfo node) {
    try {
      return _currentNodeId == node.nodeId &&
          _config.serverHost == node.host &&
          _config.serverPort == node.port;
    } catch (_) {
      return false;
    }
  }

  // Update nodes server config
  void updateNodesServerConfig({String? host, int? port, String? sessionKey}) {
    _nodeCatalogPreferences = _nodeCatalogPreferences.copyWith(
      serverHost: host,
      serverPort: port,
      sessionKey: sessionKey,
    );
    _scheduleNodeCatalogSave();
    _safeNotifyListeners();
  }

  void setSortNodesByLatency(bool enabled) {
    if (_nodeCatalogPreferences.sortByLatency == enabled) return;
    _nodeCatalogPreferences = _nodeCatalogPreferences.copyWith(
      sortByLatency: enabled,
    );
    _scheduleNodeCatalogSave();
    _safeNotifyListeners();
  }

  // Fetch nodes from server
  Future<void> fetchNodes() async {
    if (nodesServerHost.isEmpty) {
      _nodesError = 'Please enter server host';
      _safeNotifyListeners();
      return;
    }
    if (!_isValidPort(nodesServerPort)) {
      _nodesError = 'Server port must be between 1 and 65535';
      _safeNotifyListeners();
      return;
    }

    _nodeCatalogSaveTimer?.cancel();
    await _saveNodeCatalogPreferences();

    _isLoadingNodes = true;
    _nodesError = null;
    _groupsError = null;
    _safeNotifyListeners();

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
      _safeNotifyListeners();
    }
  }

  /// Measure a node's TCP handshake latency without changing the active proxy.
  ///
  /// Replaces the earlier `pingCurrentNode`, which could only measure the node
  /// already in use and only while the proxy was running.
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
    _safeNotifyListeners();
    return latency;
  }

  // Export node config to clipboard (reuse existing export logic)
  Future<void> exportNodeConfig(NodeInfo node) async {
    // Generate config for this node, preserving current settings
    final nodeConfig = node.toProxyConfig(
      localPort: _config.localPort,
      allowLan: _config.allowLan,
      sessionKey: _config.sessionKey,
      autoProxy: _config.autoProxy,
      udpEnabled: _config.udpEnabled,
      udpDirectFallback: _config.udpDirectFallback,
      tunEnabled: _config.tunEnabled,
      tunBypassProcesses: _config.tunBypassProcesses,
      androidVpnRoutingMode: _config.androidVpnRoutingMode,
      androidVpnPackages: _config.androidVpnPackages,
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
    if (_isProxyTransitioning) {
      throw StateError('Proxy operation is already in progress');
    }

    // Captured before anything is applied so a failed start can put the
    // previous node back. Reachability and the stop/restart are handled below,
    // where the TUN and non-TUN paths differ.
    final previousConfig = _config;
    final previousNodeId = _currentNodeId;

    final newConfig = node.toProxyConfig(
      localPort: _config.localPort,
      allowLan: _config.allowLan,
      sessionKey: _config.sessionKey,
      autoProxy: _config.autoProxy,
      udpEnabled: _config.udpEnabled,
      udpDirectFallback: _config.udpDirectFallback,
      tunEnabled: _isTunRunning,
      tunBypassProcesses: _config.tunBypassProcesses,
      androidVpnRoutingMode: _config.androidVpnRoutingMode,
      androidVpnPackages: _config.androidVpnPackages,
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
    final started = await start();
    if (!started) {
      _config = previousConfig;
      _currentNodeId = previousNodeId;
      unawaited(_saveConfig());
      _safeNotifyListeners();
    }
    return started;
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
      final stopResult = await _stopConfiguredTun();
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

      _config = newConfig;
      final startResult = await _startConfiguredTun();
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
      _config = previousConfig;
      final restoreResult = await _startConfiguredTun();
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
    _isDisposed = true;
    _nodeCatalogSaveTimer?.cancel();
    _logNotificationTimer?.cancel();
    unawaited(_saveNodeCatalogPreferences());
    _logSubscription?.cancel();
    unawaited(_desktopLogService.dispose());
    _service.dispose();
    unawaited(_subscriptionService?.stop() ?? Future<void>.value());
    super.dispose();
  }
}
