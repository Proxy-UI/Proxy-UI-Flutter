import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../providers/proxy_provider.dart';

class TrayService with TrayListener {
  static TrayService? _instance;
  BuildContext? _context;
  ProxyState? _proxyState;
  bool? _lastIsRunning;
  String? _lastServerLabel;
  bool _isInitialized = false;
  bool _isDisposed = false;
  Future<void> _trayTaskQueue = Future<void>.value();
  Timer? _trayHealthCheckTimer;
  bool _iconSupported = true;
  bool _toolTipSupported = true;
  bool _contextMenuSupported = true;
  bool _contextPopupSupported = true;

  TrayService._();

  static TrayService get instance {
    _instance ??= TrayService._();
    return _instance!;
  }

  Future<void> initialize(BuildContext context) async {
    if (_isInitialized && !_isDisposed) {
      _context = context;
      return;
    }
    _isDisposed = false;
    _isInitialized = true;
    _context = context;
    _iconSupported = true;
    _toolTipSupported = true;
    _contextMenuSupported = true;
    _contextPopupSupported = true;
    trayManager.addListener(this);

    _proxyState = context.read<ProxyState>();
    _lastIsRunning = _proxyState!.isRunning;
    _lastServerLabel =
        '${_proxyState!.config.serverHost}:${_proxyState!.config.serverPort}';

    await _enqueueTrayTask(() async {
      await _updateTrayIcon(_lastIsRunning!);
      await _updateTrayToolTip(_lastIsRunning!);
      await _updateTrayMenu();
    });
    _startTrayHealthCheck();

    _proxyState!.addListener(_onProxyStateChanged);
  }

  void _onProxyStateChanged() {
    if (_isDisposed || _proxyState == null) return;

    final isRunning = _proxyState!.isRunning;
    final serverLabel =
        '${_proxyState!.config.serverHost}:${_proxyState!.config.serverPort}';
    final shouldUpdateIcon = _lastIsRunning != isRunning;
    final shouldUpdateMenu =
        shouldUpdateIcon || _lastServerLabel != serverLabel;

    if (!shouldUpdateMenu) return;

    _lastIsRunning = isRunning;
    _lastServerLabel = serverLabel;

    _enqueueTrayTask(() async {
      if (shouldUpdateIcon) {
        await _updateTrayIcon(isRunning);
        await _updateTrayToolTip(isRunning);
      }
      await _updateTrayMenu();
    });
  }

  Future<void> _updateTrayIcon(bool isRunning) async {
    if (!_iconSupported) {
      return;
    }
    final iconName = isRunning ? 'tray_icon' : 'tray_icon_inactive';
    final iconPath = Platform.isWindows
        ? 'assets/tray/$iconName.ico'
        : 'assets/tray/$iconName.png';
    await _invokeTrayMethod(
      action: () => trayManager.setIcon(iconPath),
      onUnsupported: () => _iconSupported = false,
      methodName: 'setIcon',
    );
  }

  Future<void> _updateTrayToolTip(bool isRunning) async {
    if (!_toolTipSupported) {
      return;
    }
    final toolTip = isRunning ? 'Proxy Connected' : 'Proxy Disconnected';
    await _invokeTrayMethod(
      action: () => trayManager.setToolTip(toolTip),
      onUnsupported: () => _toolTipSupported = false,
      methodName: 'setToolTip',
    );
  }

  Future<void> _updateTrayMenu() async {
    if (_isDisposed || _proxyState == null || !_contextMenuSupported) return;

    final proxyState = _proxyState!;
    final isRunning = proxyState.isRunning;
    final isBusy = proxyState.isProxyOperationInProgress;
    final config = proxyState.config;
    final isWindowVisible = await _safeIsWindowVisible();

    final statusLabel = isBusy
        ? 'Proxy: Updating'
        : isRunning
        ? 'Proxy: Connected'
        : 'Proxy: Disconnected';
    final serverLabel = 'Server: ${config.serverHost}:${config.serverPort}';

    final menu = Menu(
      items: [
        MenuItem(
          key: 'show_hide',
          label: isWindowVisible ? 'Hide Window' : 'Show Window',
        ),
        MenuItem.separator(),
        MenuItem(key: 'status', label: statusLabel, disabled: true),
        MenuItem(key: 'server', label: serverLabel, disabled: true),
        MenuItem.separator(),
        MenuItem(
          key: 'start',
          label: 'Start Proxy',
          disabled: isRunning || isBusy,
        ),
        MenuItem(
          key: 'stop',
          label: 'Stop Proxy',
          disabled: !isRunning || isBusy,
        ),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit'),
      ],
    );

    await _invokeTrayMethod(
      action: () => trayManager.setContextMenu(menu),
      onUnsupported: () => _contextMenuSupported = false,
      methodName: 'setContextMenu',
    );
  }

  @override
  void onTrayIconMouseDown() {
    _toggleWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    _showContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key == null) return;
    _handleMenuClick(key);
  }

  Future<void> _toggleWindow() async {
    final isWindowVisible = await _safeIsWindowVisible();
    if (isWindowVisible) {
      await windowManager.hide();
    } else {
      await _showWindowFromTray();
    }
    await refreshMenu();
  }

  Future<void> _showContextMenu() async {
    if (!_contextPopupSupported) {
      return;
    }
    await refreshMenu();
    await _invokeTrayMethod(
      action: () => trayManager.popUpContextMenu(),
      onUnsupported: () => _contextPopupSupported = false,
      methodName: 'popUpContextMenu',
    );
  }

  Future<void> _handleMenuClick(String key) async {
    if (_context == null) return;

    switch (key) {
      case 'show_hide':
        await _toggleWindow();
        break;
      case 'start':
        await _context!.read<ProxyState>().start();
        break;
      case 'stop':
        _context!.read<ProxyState>().stop();
        break;
      case 'quit':
        await _quitApp();
        break;
    }
  }

  Future<bool> _safeIsWindowVisible() async {
    try {
      return await windowManager.isVisible();
    } catch (_) {
      return false;
    }
  }

  Future<void> _showWindowFromTray() async {
    try {
      await windowManager.show();
      await Future<void>.delayed(const Duration(milliseconds: 16));
      await windowManager.focus();
    } catch (error, stackTrace) {
      debugPrint('Show window from tray failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _startTrayHealthCheck() {
    _trayHealthCheckTimer?.cancel();
    _trayHealthCheckTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_isDisposed || _lastIsRunning == null) {
        return;
      }
      _enqueueTrayTask(() async {
        await _updateTrayIcon(_lastIsRunning!);
        await _updateTrayToolTip(_lastIsRunning!);
        await _updateTrayMenu();
      });
    });
  }

  Future<void> _invokeTrayMethod({
    required Future<void> Function() action,
    required VoidCallback onUnsupported,
    required String methodName,
  }) async {
    try {
      await action().timeout(const Duration(seconds: 2));
    } on TimeoutException {
      debugPrint('Tray method "$methodName" timed out.');
    } on MissingPluginException {
      onUnsupported();
      debugPrint('Tray method "$methodName" is unavailable on this platform.');
    } on UnimplementedError {
      onUnsupported();
      debugPrint(
        'Tray method "$methodName" is unimplemented on this platform.',
      );
    } on PlatformException catch (error) {
      final code = error.code.toLowerCase();
      if (code.contains('unimplemented') || code.contains('missing')) {
        onUnsupported();
        debugPrint(
          'Tray method "$methodName" is unsupported: ${error.code} ${error.message ?? ''}',
        );
        return;
      }
      debugPrint('Tray method "$methodName" failed: ${error.code}');
    } catch (error, stackTrace) {
      debugPrint('Tray method "$methodName" failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> handleSystemResume() async {
    if (_isDisposed || !_isInitialized || _lastIsRunning == null) {
      return;
    }
    await _enqueueTrayTask(() async {
      await _updateTrayIcon(_lastIsRunning!);
      await _updateTrayToolTip(_lastIsRunning!);
      await _updateTrayMenu();
    });

    if (await _safeIsWindowVisible()) {
      await _showWindowFromTray();
    }
  }

  Future<void> _enqueueTrayTask(Future<void> Function() task) {
    _trayTaskQueue = _trayTaskQueue.then((_) async {
      if (_isDisposed) return;
      try {
        await task();
      } catch (error, stackTrace) {
        debugPrint('Tray operation failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    });
    return _trayTaskQueue;
  }

  Future<void> refreshMenu() async {
    await _enqueueTrayTask(_updateTrayMenu);
  }

  Future<void> _quitApp() async {
    _isDisposed = true;
    _trayHealthCheckTimer?.cancel();
    _trayHealthCheckTimer = null;
    _proxyState?.removeListener(_onProxyStateChanged);

    if (_context != null) {
      final proxyState = _context!.read<ProxyState>();
      if (proxyState.isRunning) {
        proxyState.stop();
      }
    }
    await _invokeTrayMethod(
      action: () => trayManager.destroy(),
      onUnsupported: () {},
      methodName: 'destroy',
    );
    exit(0);
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _isInitialized = false;
    _trayHealthCheckTimer?.cancel();
    _trayHealthCheckTimer = null;
    _proxyState?.removeListener(_onProxyStateChanged);
    _proxyState = null;
    _context = null;
    trayManager.removeListener(this);
  }
}
