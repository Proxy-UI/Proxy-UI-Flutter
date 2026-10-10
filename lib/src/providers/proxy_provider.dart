import 'package:proxy_ui/l10n/app_language.dart';

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
import '../ffi/macos_store_proxy_service.dart';
import '../services/build_capabilities.dart';
import '../models/node_catalog_preferences.dart';
import '../models/node_group_model.dart';
import '../models/node_model.dart';
import '../models/proxy_config.dart';
import '../services/desktop_log_service.dart';
import '../services/android_vpn_service.dart';
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
  List<LogEntry>? _filteredLogs;
  StreamSubscription<LogEntry>? _logSubscription;
  StreamSubscription<void>? _connectionSubscription;
  Timer? _logNotificationTimer;
  Timer? _connectionTimer;

  /// Bumped when the log buffer changes.
  ///
  /// The log view listens to this rather than to the provider itself. Native
  /// traffic produces hundreds of entries per second, and routing that through
  /// `notifyListeners` rebuilt every screen and re-ran the tray update queue
  /// ten times a second — including while the window was hidden to the tray,
  /// which is where this app spends most of its life.
  final ValueNotifier<int> logRevision = ValueNotifier<int>(0);
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
  final Set<String> _verifyingNodes = <String>{};
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
       _service =
           service ??
           (BuildCapabilities.isMacAppStore
               ? MacosStoreProxyService()
               : ProxyService()),
       _desktopLogService = desktopLogService ?? DesktopLogService() {
    _init();
  }

  ProxyConfigModel get config => _config;
  bool get isRunning => _isRunning;
  bool get isProxyOperationInProgress => _isProxyTransitioning;
  bool get isTunRunning => _isTunRunning;
  bool get isTunBusy => _isTunBusy;
  String? get lastError => _lastError;

  /// The buffered entry count. Reading this used to copy the whole buffer.
  int get logCount => _logs.length;
  int get minLogLevel => _minLogLevel;

  /// Entries at or above the current threshold.
  ///
  /// Cached because the log view reads this on every frame it rebuilds, and
  /// re-filtering a full buffer per read is pure waste while traffic flows.
  List<LogEntry> get filteredLogs {
    return _filteredLogs ??= List<LogEntry>.unmodifiable(
      _logs.where(
        (e) => LogLevel.includes(threshold: _minLogLevel, entryLevel: e.level),
      ),
    );
  }

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
      _connectionSubscription = _service.connectionChanges.listen((_) {
        if (_isProxyTransitioning) return;
        _isRunning = _service.isRunning;
        _isTunRunning = _service.isTunRunning;
        _lastError = _service.lastError;
        _safeNotifyListeners();
      });
      await _service.initializePlatform();
      if (_isDisposed) return;
      _connectionTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _reconcileConnection(),
      );
      if (BuildCapabilities.isMacAppStore) {
        _isRunning = _service.isRunning;
        _isTunRunning = _service.isTunRunning;
      }
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
    _filteredLogs = null;
    unawaited(_persistLog(entry));
    if (_logs.length > maxLogs) {
      _logs.removeFirst();
    }
    _reconcileConnection();

    // A new log line is neither. Native traffic can produce hundreds per
    // second, so announce it on a separate channel at a human-visible cadence;
    // only the log view is listening.
    _logNotificationTimer ??= Timer(const Duration(milliseconds: 100), () {
      _logNotificationTimer = null;
      if (!_isDisposed) logRevision.value++;
    });
  }

  void _reconcileConnection() {
    if (_isDisposed || _isProxyTransitioning || _isTunBusy) return;
    var connectionChanged = false;
    if (_isRunning && !_service.isRunning) {
      _isRunning = false;
      _isTunRunning = _service.isTunRunning;
      connectionChanged = true;
    } else if (_isTunRunning && !_isTunBusy && !_service.isTunRunning) {
      _isTunRunning = false;
      _config = _config.copyWith(tunEnabled: false);
      if (Platform.isAndroid) {
        unawaited(_service.stopAndroidVpnInterface());
      }
      unawaited(_saveConfig());
      connectionChanged = true;
    }
    // A dropped connection is rare and every screen wants to know at once.
    if (connectionChanged) {
      _lastError = _service.lastError ?? _lastError;
      _safeNotifyListeners();
    }
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
        _config = _supportedConfig(
          ProxyConfigModel.fromJson(jsonDecode(configJson)),
        );
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
    // Show the last known catalogue straight away. Refreshing stays explicit,
    // so opening the nodes page no longer costs a round trip to the server.
    if (_nodeCatalogPreferences.nodes.isNotEmpty) {
      _nodes = List<NodeInfo>.of(_nodeCatalogPreferences.nodes);
      for (final node in _nodes) {
        node.latencyMs = _nodeCatalogPreferences.latencyFor(node);
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
    _config = _supportedConfig(config);
    unawaited(_saveConfig());
    _safeNotifyListeners();
  }

  bool _isValidPort(int port) => port >= 1 && port <= 65535;

  ProxyConfigModel _supportedConfig(ProxyConfigModel config) =>
      BuildCapabilities.isMacAppStore
      ? config.copyWith(
          setSystemProxy: false,
          allowLan: false,
          autoProxy: false,
          reverseGeo: false,
          tunBypassProcesses: const [],
        )
      : config;

  Future<bool> start() async {
    if (_isProxyTransitioning) {
      _lastError = appStrings.proxyOperationIsAlreadyInProgress;
      _safeNotifyListeners();
      return false;
    }
    if (_isTunBusy) {
      _lastError = appStrings.waitForTunSetupToFinish;
      _safeNotifyListeners();
      return false;
    }

    // Stop first if already running to apply new config
    if (_isRunning) {
      if (!await stop()) {
        return false;
      }
    }

    _isProxyTransitioning = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      _config = _supportedConfig(_config);
      if (_config.serverHost.isEmpty) {
        _lastError = appStrings.serverHostIsRequired;
        return false;
      }
      if (!_isValidPort(_config.serverPort)) {
        _lastError = appStrings.serverPortMustBeBetweenAnd;
        return false;
      }
      if (!_isValidPort(_config.localPort)) {
        _lastError = appStrings.localPortMustBeBetweenAnd;
        return false;
      }

      final result = await _startService(_config);

      if (result == ProxyResult.ok) {
        _isRunning = true;
        if (BuildCapabilities.isMacAppStore) {
          _isTunRunning = _service.isTunRunning;
        }
        return true;
      }

      _lastError = _service.lastError ?? ProxyResult.message(result);
      return false;
    } catch (error) {
      _lastError = appStrings.failedToStartProxy((error).toString());
      return false;
    } finally {
      _isProxyTransitioning = false;
      _safeNotifyListeners();
    }
  }

  Future<int> _startService(ProxyConfigModel config) {
    return _service.start(
      serverHost: config.serverHost,
      serverPort: config.serverPort,
      localPort: config.localPort,
      allowLan: config.allowLan,
      sessionKey: config.sessionKey,
      autoProxy: config.autoProxy,
      udpEnabled: config.udpEnabled,
      udpDirectFallback: config.udpDirectFallback,
      tunFakeIp: config.tunFakeIp,
      tunDnsServer: config.tunDnsServer,
      tunEnabled: false,
      tunBypassProcesses: config.tunBypassProcesses,
      reverseGeo: config.reverseGeo,
      needCodecIps: config.needCodecIps,
      forceCodec: config.forceCodec,
      secureTransport: config.secureTransport,
      setSystemProxy: config.setSystemProxy,
    );
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
      _lastError = appStrings.selectAtLeastOneApplicationForVpnOnlyMode;
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
        _lastError = appStrings.previousApplicationPolicyWasRestored(
          (updateError).toString(),
        );
      } else {
        _isTunRunning = false;
        _config = previous.copyWith(tunEnabled: false);
        _lastError = appStrings.previousApplicationPolicyCouldNotBeRestored(
          (updateError).toString(),
          (_service.lastError ?? ProxyResult.message(restoreResult)).toString(),
        );
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
    if (BuildCapabilities.isMacAppStore) return enabled ? start() : stop();
    if (_isTunBusy) return false;
    if (enabled == _isTunRunning) return true;
    if (enabled && !_isRunning) {
      _lastError = appStrings.startTheLocalProxyBeforeEnablingTunMode;
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
            appStrings.administratorPermissionWasNotGrantedTunModeWasNot;
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
  ///
  /// Deliberately not awaited: TUN is not yet running in this unelevated process
  /// — the whole point of the handoff is that it could not start it — so there is
  /// no route or DNS teardown to wait for, only the listener to release.
  void stopForElevationHandoff() {
    if (_isRunning) {
      unawaited(_service.stop());
    }
    _isRunning = false;
    _isTunRunning = false;
    notifyListeners();
  }

  /// Stop the proxy and any TUN session it owns.
  ///
  /// Completes only after native teardown has restored the system routes and
  /// DNS, so a caller that exits the process afterwards cannot cut that short.
  Future<bool> stop() async {
    if (_isProxyTransitioning) {
      _lastError = appStrings.proxyOperationIsAlreadyInProgress;
      _safeNotifyListeners();
      return false;
    }
    if (_isTunBusy) return false;
    // TUN can outlive the listener if a previous stop failed part-way. Cancel it
    // rather than returning early, or its routes and DNS stay installed.
    if (!_isRunning) {
      if (_isTunRunning) {
        await setTunEnabled(false);
      }
      return true;
    }

    _isProxyTransitioning = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      // `proxy_stop` cancels the TUN child token before the local listener
      // token, so no separate blocking FFI call is needed on whole-proxy
      // shutdown.
      final result = await _service.stop();
      if (result == ProxyResult.ok || result == ProxyResult.notRunning) {
        _isRunning = false;
        _isTunRunning = false;
        _config = _config.copyWith(tunEnabled: false);
        unawaited(_saveConfig());
        return true;
      } else {
        _lastError = _service.lastError ?? ProxyResult.message(result);
        return false;
      }
    } finally {
      _isProxyTransitioning = false;
      _safeNotifyListeners();
    }
  }

  void clearLogs() {
    _logs.clear();
    _filteredLogs = null;
    if (!_isDisposed) logRevision.value++;
    _safeNotifyListeners();
  }

  void setMinLogLevel(int level) {
    _minLogLevel = LogLevel.normalize(level);
    _filteredLogs = null;
    // Also raise the native floor so the levels the UI filters out are never
    // shipped across the FFI boundary in the first place.
    _service.setLogLevel(_minLogLevel);
    if (!_isDisposed) logRevision.value++;
    _safeNotifyListeners();
  }

  Future<void> startSubscriptionService({int port = 8080}) async {
    if (BuildCapabilities.isMacAppStore) {
      throw UnsupportedError(
        'LAN configuration sharing is unavailable in the Store edition.',
      );
    }
    if (_subscriptionServiceRunning || _subscriptionServiceBusy) return;
    if (!_isValidPort(port)) {
      throw ArgumentError.value(port, 'port', appStrings.portMustBeBetweenAnd);
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
      _nodesError = appStrings.pleaseEnterServerHost;
      _safeNotifyListeners();
      return;
    }
    if (!_isValidPort(nodesServerPort)) {
      _nodesError = appStrings.serverPortMustBeBetweenAnd;
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
        // Cache the catalogue so the next visit to the nodes page starts from
        // the last known servers instead of an empty list.
        _nodeCatalogPreferences = _nodeCatalogPreferences.withCatalog(
          _nodes,
          DateTime.now(),
        );
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

  NodeVerification? verificationFor(NodeInfo node) =>
      _nodeCatalogPreferences.verificationFor(node);

  /// The country to show for a node: what its traffic actually says, falling
  /// back to what the catalogue claims.
  String effectiveCountry(NodeInfo node) {
    final verification = verificationFor(node);
    if (verification != null &&
        verification.isVerified &&
        verification.countryCode.isNotEmpty) {
      return verification.countryCode;
    }
    return node.country;
  }

  bool isVerifyingNode(NodeInfo node) =>
      _verifyingNodes.contains(node.storageKey);

  /// Test a node: how long a real round trip through it takes, and where that
  /// traffic leaves from.
  ///
  /// One request answers both, because both need the same thing — bytes that
  /// actually travelled through the node.
  ///
  /// A TCP handshake answers neither. With TUN capturing, every address except
  /// the current upstream is intercepted, and the local user-space stack
  /// replies to the SYN itself, so a connect returns in under a millisecond
  /// whether the node is alive or dead. The catalogue's country is a claim for
  /// the same reason: it is where the server registered, not where its traffic
  /// leaves from.
  ///
  /// The answer is persisted, including a failure, because "this node did not
  /// answer" is worth remembering too.
  Future<NodeVerification?> verifyNode(NodeInfo node) async {
    final key = node.storageKey;
    if (_verifyingNodes.contains(key)) return null;
    _verifyingNodes.add(key);
    _safeNotifyListeners();

    try {
      final probe = await _service.probeNode(
        serverHost: node.host,
        serverPort: node.port,
        forceCodec: _config.forceCodec,
        secureTransport: _config.secureTransport,
      );
      final verification = NodeVerification(
        status: probe.success
            ? NodeVerificationStatus.verified
            : NodeVerificationStatus.unreachable,
        checkedAt: DateTime.now(),
        countryCode: probe.countryCode,
        egressIp: probe.egressIp,
        latencyMs: probe.latencyMs,
        error: probe.error,
      );
      _nodeCatalogPreferences = _nodeCatalogPreferences.withVerification(
        node,
        verification,
      );
      // A failed test leaves the previous latency alone rather than replacing
      // it with a number that measured nothing.
      if (probe.success && probe.latencyMs != null) {
        node.latencyMs = probe.latencyMs;
        _nodeCatalogPreferences = _nodeCatalogPreferences.withLatency(
          node,
          probe.latencyMs!,
        );
      }
      await _saveNodeCatalogPreferences();
      return verification;
    } catch (error) {
      final verification = NodeVerification(
        status: NodeVerificationStatus.unreachable,
        checkedAt: DateTime.now(),
        error: error.toString(),
      );
      _nodeCatalogPreferences = _nodeCatalogPreferences.withVerification(
        node,
        verification,
      );
      await _saveNodeCatalogPreferences();
      return verification;
    } finally {
      _verifyingNodes.remove(key);
      _safeNotifyListeners();
    }
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
      tunFakeIp: _config.tunFakeIp,
      tunDnsServer: _config.tunDnsServer,
      tunEnabled: _config.tunEnabled,
      tunBypassProcesses: _config.tunBypassProcesses,
      androidVpnRoutingMode: _config.androidVpnRoutingMode,
      androidVpnPackages: _config.androidVpnPackages,
      reverseGeo: _config.reverseGeo,
      needCodecIps: _config.needCodecIps,
      forceCodec: _config.forceCodec,
      secureTransport: _config.secureTransport,
      setSystemProxy: _config.setSystemProxy,
    );

    final json = jsonEncode(nodeConfig.toJson());
    final encoded = base64Encode(utf8.encode(json));
    await Clipboard.setData(ClipboardData(text: encoded));
  }

  // Switch to a different node
  Future<bool> switchToNode(NodeInfo node) async {
    if (_isProxyTransitioning) {
      throw StateError(appStrings.proxyOperationIsAlreadyInProgress);
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
      tunFakeIp: _config.tunFakeIp,
      tunDnsServer: _config.tunDnsServer,
      tunEnabled: _isTunRunning,
      tunBypassProcesses: _config.tunBypassProcesses,
      androidVpnRoutingMode: _config.androidVpnRoutingMode,
      androidVpnPackages: _config.androidVpnPackages,
      reverseGeo: _config.reverseGeo,
      needCodecIps: _config.needCodecIps,
      forceCodec: _config.forceCodec,
      secureTransport: _config.secureTransport,
      setSystemProxy: _config.setSystemProxy,
    );

    if (_isRunning && _isTunRunning && !BuildCapabilities.isMacAppStore) {
      return _hotSwitchTunNode(node, newConfig);
    }

    if (BuildCapabilities.isMacAppStore) {
      return _switchStoreNode(node, _supportedConfig(newConfig));
    }

    await _ensureNodeReachable(node);

    // Outside TUN mode, preserve the established restart behavior because
    // non-TUN HTTP/SOCKS sessions are not owned by the TUN relay and therefore
    // cannot all be drained by stopping capture.
    if (_isRunning) {
      if (!await stop()) return false;
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

  /// A provider owns both capture and the listener, so a node change replaces
  /// the whole VPN session. Probe after disconnecting to avoid routing the new
  /// endpoint through the old node. Keep the operation locked through rollback.
  Future<bool> _switchStoreNode(
    NodeInfo node,
    ProxyConfigModel newConfig,
  ) async {
    if (_isTunBusy) return false;
    final previous = _config;
    final previousNode = _currentNodeId;
    final wasRunning = _service.isRunning;
    _isProxyTransitioning = true;
    _lastError = null;
    _safeNotifyListeners();
    try {
      if (wasRunning) {
        final stopped = await _service.stop();
        if (stopped != ProxyResult.ok && stopped != ProxyResult.notRunning) {
          _lastError = _service.lastError ?? ProxyResult.message(stopped);
          return false;
        }
      }
      String? failure;
      try {
        await _ensureNodeReachable(node);
        final started = await _startService(newConfig);
        if (started != ProxyResult.ok || !_service.isRunning) {
          failure =
              _service.lastError ??
              ProxyResult.message(ProxyResult.runtimeError);
        }
      } catch (error) {
        failure = error.toString();
      }
      if (failure == null) {
        _config = newConfig;
        _currentNodeId = node.nodeId;
        await _saveConfig();
        return true;
      }
      _config = previous;
      _currentNodeId = previousNode;
      _lastError = failure;
      if (wasRunning) {
        // A timed-out start can still be disconnecting in the system. Await
        // cleanup before starting the prior session with its original config.
        final cleaned = await _service.stop();
        final restored =
            cleaned == ProxyResult.ok || cleaned == ProxyResult.notRunning
            ? await _startService(previous)
            : ProxyResult.runtimeError;
        _lastError = restored == ProxyResult.ok && _service.isRunning
            ? appStrings.previousNodeAndTunRoutesWereRestored(failure)
            : appStrings.rollbackCouldNotRestoreTunModeTrafficCaptureIs(
                failure,
                _service.lastError ?? ProxyResult.message(restored),
              );
      }
      await _saveConfig();
      return false;
    } finally {
      _isRunning = _service.isRunning;
      _isTunRunning = _service.isTunRunning;
      _isProxyTransitioning = false;
      _safeNotifyListeners();
    }
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
      throw Exception(appStrings.nodeUnreachable((error.message).toString()));
    } on TimeoutException {
      throw Exception(appStrings.nodeUnreachableConnectionTimeout);
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
      _lastError = appStrings.waitForTheCurrentTunOperationToFinish;
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
            appStrings.failedToPauseTunForNodeSwitch(
              (ProxyResult.message(stopResult)).toString(),
            );
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
          appStrings.cannotSwitchTo(
            (node.displayName).toString(),
            (error).toString(),
          ),
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
              appStrings.failedToSwitchUpstream(
                (ProxyResult.message(switchResult)).toString(),
              ),
          endpointChanged: false,
        );
      }

      _config = newConfig;
      final startResult = await _startConfiguredTun();
      if (startResult != ProxyResult.ok) {
        final switchError =
            _service.lastError ??
            appStrings.failedToRestartTunFor(
              (node.displayName).toString(),
              (ProxyResult.message(startResult)).toString(),
            );
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
            appStrings.upstreamRollbackReturned(
              (ProxyResult.message(switchBackResult)).toString(),
            );
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
      _lastError = appStrings.previousNodeAndTunRoutesWereRestored(
        (failure).toString(),
      );
    } else {
      _config = previousConfig.copyWith(tunEnabled: false);
      _isTunRunning = false;
      _lastError = appStrings.rollbackCouldNotRestoreTunModeTrafficCaptureIs(
        (failure).toString(),
        (rollbackError).toString(),
      );
    }
    await _saveConfig();
    return false;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _nodeCatalogSaveTimer?.cancel();
    _logNotificationTimer?.cancel();
    _connectionTimer?.cancel();
    unawaited(_saveNodeCatalogPreferences());
    _logSubscription?.cancel();
    _connectionSubscription?.cancel();
    unawaited(_desktopLogService.dispose());
    _service.dispose();
    unawaited(_subscriptionService?.stop() ?? Future<void>.value());
    logRevision.dispose();
    super.dispose();
  }
}
