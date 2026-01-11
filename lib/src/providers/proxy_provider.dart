import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ffi/proxy_ffi.dart';
import '../ffi/proxy_service.dart';
import '../models/proxy_config.dart';
import '../services/subscription_service.dart';
import '../services/vpn_service.dart';

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

  // VPN service (Android only)
  VpnService? _vpnService;
  bool _vpnRunning = false;
  bool _vpnStarting = false;
  bool _vpnSupported = false;

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

  // VPN getters
  bool get vpnRunning => _vpnRunning;
  bool get vpnStarting => _vpnStarting;
  bool get vpnSupported => _vpnSupported;

  Future<void> _init() async {
    _service.initLogging();
    _logSubscription = ProxyService.logStream.listen(_onLog);
    await _loadConfig();

    // Initialize VPN service on Android
    if (Platform.isAndroid) {
      _vpnService = VpnService();
      _vpnSupported = VpnService.isSupported;
      if (_vpnSupported) {
        _vpnRunning = await _vpnService!.isRunning();

        // Listen for VPN events from Android (tun fd, errors, stop, revoke).
        _vpnService!.setMethodCallHandler((MethodCall call) async {
          switch (call.method) {
            case 'vpn_started':
              final args =
                  (call.arguments as Map<Object?, Object?>?) ?? const {};
              final tunFd = (args['fd'] as int?) ?? -1;
              await _handleVpnStarted(tunFd);
              break;
            case 'vpn_stopped':
              _vpnStarting = false;
              _vpnRunning = false;
              _service.stop(); // best-effort stop native core
              notifyListeners();
              break;
            case 'vpn_error':
              final args =
                  (call.arguments as Map<Object?, Object?>?) ?? const {};
              _lastError = (args['error'] as String?) ?? 'VPN error';
              _vpnStarting = false;
              _vpnRunning = false;
              _service.stop(); // best-effort stop native core
              notifyListeners();
              break;
            case 'vpn_revoked':
              _lastError = 'VPN permission revoked';
              _vpnStarting = false;
              _vpnRunning = false;
              _service.stop(); // best-effort stop native core
              notifyListeners();
              break;
          }
        });
      }
    }
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

  // VPN methods (Android only)
  Future<bool> startVpn() async {
    if (!_vpnSupported || _vpnService == null) {
      _lastError = 'VPN is not supported on this platform';
      notifyListeners();
      return false;
    }

    // Ensure server config is present.
    if (_config.serverHost.isEmpty) {
      _lastError = 'Server host is required';
      notifyListeners();
      return false;
    }

    if (_vpnRunning || _vpnStarting) {
      return true;
    }

    // Stop local proxy mode if running (VPN mode is mutually exclusive).
    if (_isRunning) {
      stop();
    }

    try {
      _vpnStarting = true;
      _lastError = null;
      notifyListeners();

      final success = await _vpnService!.start();
      if (success) {
        // Wait for 'vpn_started' event to receive TUN FD and start native core.
        return true;
      } else {
        _lastError = 'Failed to start VPN';
        _vpnStarting = false;
        notifyListeners();
        return false;
      }
    } on VpnPermissionDeniedException {
      _lastError = 'VPN permission denied';
      _vpnStarting = false;
      notifyListeners();
      return false;
    } catch (e) {
      _lastError = 'VPN error: $e';
      _vpnStarting = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> stopVpn() async {
    if (!_vpnSupported || _vpnService == null) {
      return false;
    }

    _vpnStarting = false;

    try {
      // Stop native core first so it can close the TUN FD.
      _service.stop();

      final success = await _vpnService!.stop();
      if (success) {
        _vpnRunning = false;
        notifyListeners();
        return true;
      } else {
        _lastError = 'Failed to stop VPN';
        notifyListeners();
        return false;
      }
    } catch (e) {
      _lastError = 'VPN error: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> checkVpnPermission() async {
    if (!_vpnSupported || _vpnService == null) {
      return false;
    }

    try {
      return await _vpnService!.isPermissionGranted();
    } catch (e) {
      return false;
    }
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _service.dispose();
    _subscriptionService?.stop();
    super.dispose();
  }

  Future<void> _handleVpnStarted(int tunFd) async {
    _vpnStarting = false;

    if (tunFd < 0) {
      _lastError = 'Invalid TUN FD from Android';
      _vpnRunning = false;
      notifyListeners();
      await _vpnService?.stop();
      return;
    }

    // Start native VPN core (TUN handler).
    final result = await _service.startVpn(
      tunFd: tunFd,
      serverHost: _config.serverHost,
      serverPort: _config.serverPort,
      sessionKey: _config.sessionKey,
      autoProxy: _config.autoProxy,
      reverseGeo: _config.reverseGeo,
      needCodecIps: _config.needCodecIps,
      forceCodec: _config.forceCodec,
    );

    if (result == ProxyResult.ok) {
      _vpnRunning = true;
      _isRunning = false;
      _lastError = null;
    } else {
      _lastError = ProxyResult.message(result);
      _vpnRunning = false;
      await _vpnService?.stop();
    }

    notifyListeners();
  }
}
