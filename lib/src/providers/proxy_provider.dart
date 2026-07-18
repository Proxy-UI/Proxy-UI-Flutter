import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String _nodesServerHost = '';
  int _nodesServerPort = 1081;
  String? _nodesSessionKey;

  static const int maxLogs = 1000;
  static const String _configKey = 'proxy_config';

  ProxyState() {
    _init();
  }

  ProxyConfigModel get config => _config;
  bool get isRunning => _isRunning;
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
  String get nodesServerHost => _nodesServerHost;
  int get nodesServerPort => _nodesServerPort;
  String? get nodesSessionKey => _nodesSessionKey;

  Future<void> _init() async {
    _service.initLogging();
    _logSubscription = ProxyService.logStream.listen(_onLog);
    await _loadConfig();
  }

  void _onLog(LogEntry entry) {
    _logs.add(entry);
    if (_logs.length > maxLogs) {
      _logs.removeAt(0);
    }
    notifyListeners();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final configJson = prefs.getString(_configKey);
    if (configJson != null) {
      try {
        _config = ProxyConfigModel.fromJson(jsonDecode(configJson));
        notifyListeners();
      } catch (_) {
        // Ignore invalid config
      }
    }
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configKey, jsonEncode(_config.toJson()));
  }

  void updateConfig(ProxyConfigModel config) {
    _config = config;
    _saveConfig();
    notifyListeners();
  }

  Future<bool> start() async {
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

  bool stop() {
    if (!_isRunning) return true;

    final result = _service.stop();
    if (result == ProxyResult.ok || result == ProxyResult.notRunning) {
      _isRunning = false;
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
    if (host != null) _nodesServerHost = host;
    if (port != null) _nodesServerPort = port;
    if (sessionKey != null) _nodesSessionKey = sessionKey;
    notifyListeners();
  }

  // Fetch nodes from server
  Future<void> fetchNodes() async {
    if (_nodesServerHost.isEmpty) {
      _nodesError = 'Please enter server host';
      notifyListeners();
      return;
    }

    _isLoadingNodes = true;
    _nodesError = null;
    _groupsError = null;
    notifyListeners();

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
      notifyListeners();
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
        notifyListeners();
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
      udpEnabled: _config.udpEnabled,
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
      stop();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Update config with new node
    final newConfig = node.toProxyConfig(
      localPort: _config.localPort,
      sessionKey: _config.sessionKey,
      autoProxy: _config.autoProxy,
      udpEnabled: _config.udpEnabled,
      reverseGeo: _config.reverseGeo,
      needCodecIps: _config.needCodecIps,
      forceCodec: _config.forceCodec,
      setSystemProxy: _config.setSystemProxy,
    );

    updateConfig(newConfig);
    _currentNodeId = node.nodeId;

    // Start proxy with new config
    return await start();
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _service.dispose();
    _subscriptionService?.stop();
    super.dispose();
  }
}
