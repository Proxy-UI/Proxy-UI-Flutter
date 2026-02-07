import 'dart:io';
import 'package:flutter/material.dart';
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

  TrayService._();

  static TrayService get instance {
    _instance ??= TrayService._();
    return _instance!;
  }

  Future<void> initialize(BuildContext context) async {
    if (_isInitialized && !_isDisposed) return;
    _isDisposed = false;
    _isInitialized = true;
    _context = context;
    trayManager.addListener(this);

    _proxyState = context.read<ProxyState>();
    _lastIsRunning = _proxyState!.isRunning;
    _lastServerLabel =
        '${_proxyState!.config.serverHost}:${_proxyState!.config.serverPort}';

    await _enqueueTrayTask(() async {
      await _updateTrayIcon(_lastIsRunning!);
      await _updateTrayMenu();
    });

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
      }
      await _updateTrayMenu();
    });
  }

  Future<void> _updateTrayIcon(bool isRunning) async {
    final iconName = isRunning ? 'tray_icon' : 'tray_icon_inactive';
    final iconPath = Platform.isWindows
        ? 'assets/tray/$iconName.ico'
        : 'assets/tray/$iconName.png';
    await trayManager.setIcon(iconPath);
  }

  Future<void> _updateTrayMenu() async {
    if (_isDisposed || _proxyState == null) return;

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

    await trayManager.setContextMenu(menu);
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
      await windowManager.show();
      await windowManager.focus();
    }
    await refreshMenu();
  }

  Future<void> _showContextMenu() async {
    await refreshMenu();
    try {
      await trayManager.popUpContextMenu();
    } catch (error, stackTrace) {
      debugPrint('Tray pop-up menu failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
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
      return true;
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
    _proxyState?.removeListener(_onProxyStateChanged);

    if (_context != null) {
      final proxyState = _context!.read<ProxyState>();
      if (proxyState.isRunning) {
        proxyState.stop();
      }
    }
    await trayManager.destroy();
    exit(0);
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _isInitialized = false;
    _proxyState?.removeListener(_onProxyStateChanged);
    _proxyState = null;
    _context = null;
    trayManager.removeListener(this);
  }
}
