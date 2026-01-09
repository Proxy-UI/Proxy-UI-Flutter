import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ffi/proxy_ffi.dart';
import '../ffi/proxy_service.dart';
import '../models/proxy_config.dart';

/// Proxy state provider for UI.
class ProxyState extends ChangeNotifier {
  final ProxyService _service = ProxyService();
  ProxyConfigModel _config = ProxyConfigModel();
  bool _isRunning = false;
  String? _lastError;
  final List<LogEntry> _logs = [];
  StreamSubscription<LogEntry>? _logSubscription;
  int _minLogLevel = 0; // 0=trace, 1=debug, 2=info, 3=warn, 4=error

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
      reverseGeo: _config.reverseGeo,
      needCodecIps: _config.needCodecIps,
      forceCodec: _config.forceCodec,
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

  @override
  void dispose() {
    _logSubscription?.cancel();
    _service.dispose();
    super.dispose();
  }
}
