import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

import '../ffi/proxy_ffi.dart';
import '../ffi/proxy_service.dart';
import '../models/node_group_model.dart';
import '../models/node_model.dart';
import '../models/proxy_config.dart';
import '../services/subscription_service.dart';

/// Proxy state provider for UI.
class ProxyState extends ChangeNotifier {
  final ProxyService _service = ProxyService();
  ProxyConfigModel _config = ProxyConfigModel();
  bool _isRunning = false;
  bool _isProxyTransitioning = false;
  String? _lastError;
  final List<LogEntry> _logs = [];
  StreamSubscription<LogEntry>? _logSubscription;
  int _minLogLevel = 0; // 0=trace, 1=debug, 2=info, 3=warn, 4=error

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
  String _nodesServerHost = '';
  int _nodesServerPort = 1081;
  String? _nodesSessionKey;
  bool _isDisposed = false;

  static const int maxLogs = 1000;
  static const String _configKey = 'proxy_config';

  ProxyState() {
    _init();
  }

  ProxyConfigModel get config => _config;
  bool get isRunning => _isRunning;
  bool get isProxyOperationInProgress => _isProxyTransitioning;
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
  String get nodesServerHost => _nodesServerHost;
  int get nodesServerPort => _nodesServerPort;
  String? get nodesSessionKey => _nodesSessionKey;

  void _safeNotifyListeners() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  Future<void> _init() async {
    try {
      _service.initLogging();
      _logSubscription = ProxyService.logStream.listen(_onLog);
      await _loadConfig();
    } catch (error, stackTrace) {
      debugPrint('ProxyState init failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _onLog(LogEntry entry) {
    _logs.add(entry);
    if (_logs.length > maxLogs) {
      _logs.removeAt(0);
    }
    _safeNotifyListeners();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final configJson = prefs.getString(_configKey);
    if (configJson != null) {
      try {
        _config = ProxyConfigModel.fromJson(jsonDecode(configJson));
        _safeNotifyListeners();
      } catch (_) {
        // Ignore invalid config
      }
    }
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
        sessionKey: _config.sessionKey,
        autoProxy: _config.autoProxy,
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

  bool stop() {
    if (_isProxyTransitioning) {
      _lastError = 'Proxy operation is already in progress';
      _safeNotifyListeners();
      return false;
    }
    if (!_isRunning) return true;

    _isProxyTransitioning = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final result = _service.stop();
      if (result == ProxyResult.ok || result == ProxyResult.notRunning) {
        _isRunning = false;
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
    if (host != null) _nodesServerHost = host;
    if (port != null) _nodesServerPort = port;
    if (sessionKey != null) _nodesSessionKey = sessionKey;
    _safeNotifyListeners();
  }

  // Fetch nodes from server
  Future<void> fetchNodes() async {
    if (_nodesServerHost.isEmpty) {
      _nodesError = 'Please enter server host';
      _safeNotifyListeners();
      return;
    }
    if (!_isValidPort(_nodesServerPort)) {
      _nodesError = 'Server port must be between 1 and 65535';
      _safeNotifyListeners();
      return;
    }

    _isLoadingNodes = true;
    _nodesError = null;
    _groupsError = null;
    _safeNotifyListeners();

    try {
      final nodesFuture = _service.getServerNodes(
        serverHost: _nodesServerHost,
        serverPort: _nodesServerPort,
        sessionKey: _nodesSessionKey?.isEmpty ?? true ? null : _nodesSessionKey,
      );

      final groupsFuture = _service.getServerGroups(
        serverHost: _nodesServerHost,
        serverPort: _nodesServerPort,
        sessionKey: _nodesSessionKey?.isEmpty ?? true ? null : _nodesSessionKey,
      );

      try {
        _nodes = await nodesFuture;
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

  // Test latency for current node (only works when proxy is running)
  Future<void> pingCurrentNode() async {
    if (!_isRunning) {
      throw StateError('Proxy must be running to test latency');
    }

    try {
      final latency = await _service.testLatency();

      // Update latency for current node
      final currentIndex = _nodes.indexWhere((n) => isCurrentNode(n));
      if (currentIndex != -1) {
        _nodes[currentIndex].latencyMs = latency;
        _safeNotifyListeners();
      }
    } catch (e) {
      rethrow;
    }
  }

  // Export node config to clipboard (reuse existing export logic)
  Future<void> exportNodeConfig(NodeInfo node) async {
    // Generate config for this node, preserving current settings
    final nodeConfig = node.toProxyConfig(
      localPort: _config.localPort,
      sessionKey: _config.sessionKey,
      autoProxy: _config.autoProxy,
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

    // Test connectivity first
    try {
      final socket = await Socket.connect(
        node.host,
        node.port,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
    } on SocketException catch (e) {
      throw Exception('Node unreachable: ${e.message}');
    } on TimeoutException {
      throw Exception('Node unreachable: connection timeout');
    }

    // Stop current proxy if running
    if (_isRunning) {
      if (!stop()) {
        throw StateError(_lastError ?? 'Failed to stop current proxy');
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    final previousConfig = _config;
    final previousNodeId = _currentNodeId;

    // Update config with new node
    final newConfig = node.toProxyConfig(
      localPort: _config.localPort,
      sessionKey: _config.sessionKey,
      autoProxy: _config.autoProxy,
      reverseGeo: _config.reverseGeo,
      needCodecIps: _config.needCodecIps,
      forceCodec: _config.forceCodec,
      setSystemProxy: _config.setSystemProxy,
    );

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

  @override
  void dispose() {
    _isDisposed = true;
    _logSubscription?.cancel();
    _service.dispose();
    unawaited(_subscriptionService?.stop() ?? Future<void>.value());
    super.dispose();
  }
}
