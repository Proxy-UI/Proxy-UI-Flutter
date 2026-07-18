import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../providers/proxy_provider.dart';

enum _TrayStatus { connected, disconnected, error }

class TrayService with TrayListener {
  static TrayService? _instance;
  BuildContext? _context;
  bool _isWindowVisible = true;
  _TrayStatus? _currentIconStatus;
  int? _currentMenuSignature;

  TrayService._();

  static TrayService get instance {
    _instance ??= TrayService._();
    return _instance!;
  }

  Future<void> initialize(BuildContext context) async {
    _context = context;
    trayManager.addListener(this);

    await _updateTrayIcon(_TrayStatus.disconnected);
    await _updateTrayMenu();

    if (_context != null) {
      _context!.read<ProxyState>().addListener(_onProxyStateChanged);
    }
  }

  void _onProxyStateChanged() {
    if (_context != null) {
      final proxyState = _context!.read<ProxyState>();
      _updateTrayIcon(_statusFor(proxyState));
      _updateTrayMenu();
    }
  }

  _TrayStatus _statusFor(ProxyState proxyState) {
    if (proxyState.isRunning) return _TrayStatus.connected;
    if (proxyState.lastError != null) return _TrayStatus.error;
    return _TrayStatus.disconnected;
  }

  Future<void> _updateTrayIcon(_TrayStatus status) async {
    // ProxyState also notifies for every log line. Avoid repeatedly replacing
    // the native tray icon when the connection state has not changed.
    if (_currentIconStatus == status) return;
    _currentIconStatus = status;

    final (iconName, tooltipStatus) = switch (status) {
      _TrayStatus.connected => ('tray_icon', 'Connected'),
      _TrayStatus.disconnected => ('tray_icon_inactive', 'Disconnected'),
      _TrayStatus.error => ('tray_icon_error', 'Connection error'),
    };
    final iconPath = Platform.isWindows
        ? 'assets/tray/$iconName.ico'
        : 'assets/tray/$iconName.png';
    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip('Proxy Everything - $tooltipStatus');
  }

  Future<void> _updateTrayMenu() async {
    if (_context == null) return;

    final proxyState = _context!.read<ProxyState>();
    final isRunning = proxyState.isRunning;
    final config = proxyState.config;
    final status = _statusFor(proxyState);
    final menuSignature = Object.hash(
      _isWindowVisible,
      status,
      config.serverHost,
      config.serverPort,
    );
    if (_currentMenuSignature == menuSignature) return;
    _currentMenuSignature = menuSignature;

    final statusLabel = switch (status) {
      _TrayStatus.connected => 'Proxy: Connected',
      _TrayStatus.disconnected => 'Proxy: Disconnected',
      _TrayStatus.error => 'Proxy: Connection error',
    };
    final serverLabel = 'Server: ${config.serverHost}:${config.serverPort}';

    final menu = Menu(
      items: [
        MenuItem(
          key: 'show_hide',
          label: _isWindowVisible ? 'Hide Window' : 'Show Window',
        ),
        MenuItem.separator(),
        MenuItem(key: 'status', label: statusLabel, disabled: true),
        MenuItem(key: 'server', label: serverLabel, disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'start', label: 'Start Proxy', disabled: isRunning),
        MenuItem(key: 'stop', label: 'Stop Proxy', disabled: !isRunning),
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
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    _handleMenuClick(menuItem.key!);
  }

  Future<void> _toggleWindow() async {
    if (_isWindowVisible) {
      await windowManager.hide();
      _isWindowVisible = false;
    } else {
      await windowManager.show();
      await windowManager.focus();
      _isWindowVisible = true;
    }
    await _updateTrayMenu();
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

  Future<void> _quitApp() async {
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
    trayManager.removeListener(this);
  }
}
