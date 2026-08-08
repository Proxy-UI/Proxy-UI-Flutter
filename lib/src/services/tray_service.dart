import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/proxy_provider.dart';
import 'window_state_service.dart';

enum _TrayStatus { connected, disconnected, error }

/// Owns the desktop notification icon and keeps it consistent with
/// [ProxyState].
///
/// Every shell call is funnelled through a single queue. `ProxyState` notifies
/// on a 100 ms log cadence while traffic flows, and overlapping
/// `Shell_NotifyIcon` calls on Windows race on the same notification icon.
class TrayService with TrayListener {
  static TrayService? _instance;
  ProxyState? _proxyState;
  bool _isWindowVisible = true;
  bool _initialized = false;
  bool _isDisposed = false;

  /// State the shell has actually accepted. Both are cleared before a platform
  /// call and only restored after it succeeds, so a failed call can never leave
  /// the tray frozen on a stale icon or menu.
  _TrayStatus? _appliedIconStatus;
  int? _appliedMenuSignature;

  Future<void> _queue = Future<void>.value();
  bool _needsRebuild = false;

  /// Latched off when a platform reports a tray call as unimplemented, so a
  /// desktop without a system tray is asked once instead of on every update.
  bool _trayAvailable = true;

  /// Catches the case no event reports: the shell dropping the icon while the
  /// app has nothing to react to. A re-assert is a single `NIM_MODIFY`.
  Timer? _healthCheckTimer;
  static const Duration _healthCheckInterval = Duration(seconds: 20);

  /// A wedged shell must not stall the queue behind it forever.
  static const Duration _callTimeout = Duration(seconds: 2);

  TrayService._();

  static TrayService get instance {
    _instance ??= TrayService._();
    return _instance!;
  }

  Future<void> initialize(ProxyState proxyState) async {
    if (_initialized) return;
    _initialized = true;
    _isDisposed = false;
    _trayAvailable = true;

    _proxyState = proxyState;
    trayManager.addListener(this);
    proxyState.addListener(_onProxyStateChanged);

    try {
      _isWindowVisible = await windowManager.isVisible();
    } catch (error) {
      debugPrint('Failed to read initial window visibility: $error');
    }
    await _enqueue(_applyTray);
    _startHealthCheck();
  }

  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(_healthCheckInterval, (_) {
      if (_isDisposed || !_trayAvailable) return;
      unawaited(
        _enqueue(() async {
          _appliedIconStatus = null;
          _appliedMenuSignature = null;
          await _applyIcon();
          await _applyMenu();
        }),
      );
    });
  }

  /// Recreates the icon after the machine wakes up.
  ///
  /// Resume is the one moment where the shell is most likely to have dropped
  /// the icon, and a plain re-assert cannot bring back an icon that is gone —
  /// only a delete and re-add can.
  Future<void> handleSystemResume() async {
    if (_isDisposed || !_initialized) return;
    await rebuild();
    await _refreshWindowVisibility();
  }

  /// Redraws the context menu from the current state.
  Future<void> refreshMenu() {
    return _enqueue(() async {
      _appliedMenuSignature = null;
      await _applyMenu();
    });
  }

  /// Deletes and re-adds the notification icon.
  ///
  /// `NIM_MODIFY` silently fails once the shell has dropped an icon, so a
  /// disappeared icon can only be recovered by adding it again.
  Future<void> rebuild() {
    _needsRebuild = true;
    return _enqueue(_applyTray);
  }

  void _onProxyStateChanged() {
    unawaited(_enqueue(_applyTray));
  }

  /// Serializes tray work and keeps the queue alive across failures.
  Future<void> _enqueue(Future<void> Function() action) {
    _queue = _queue
        .then((_) async {
          if (_isDisposed) return;
          await action();
        })
        .catchError((Object error) {
          // The shell rejected the update. Recreate the icon on the next pass
          // rather than leaving the tray stuck on whatever it last accepted.
          _needsRebuild = true;
          debugPrint('Tray update failed: $error');
        });
    return _queue;
  }

  /// Runs one tray call, bounded in time and tolerant of platforms that do not
  /// implement a tray at all.
  ///
  /// Returns false when the call did not take effect, so callers keep their
  /// "applied" state cleared and retry on the next pass.
  Future<bool> _call(Future<void> Function() action, String name) async {
    if (!_trayAvailable) return false;
    try {
      await action().timeout(_callTimeout);
      return true;
    } on TimeoutException {
      debugPrint('Tray call "$name" timed out');
      return false;
    } on MissingPluginException {
      _trayAvailable = false;
      debugPrint('No tray implementation available; disabling tray updates');
      return false;
    } on UnimplementedError {
      _trayAvailable = false;
      debugPrint('Tray is unimplemented on this platform');
      return false;
    } on PlatformException catch (error) {
      final code = error.code.toLowerCase();
      if (code.contains('unimplemented') || code.contains('missing')) {
        _trayAvailable = false;
        debugPrint('Tray is unsupported here: ${error.code}');
        return false;
      }
      debugPrint('Tray call "$name" failed: ${error.code} ${error.message}');
      return false;
    }
  }

  Future<void> _applyTray() async {
    if (_needsRebuild) {
      _needsRebuild = false;
      _appliedIconStatus = null;
      _appliedMenuSignature = null;
      await _call(trayManager.destroy, 'destroy');
    }
    await _applyIcon();
    await _applyMenu();
  }

  _TrayStatus _statusFor(ProxyState proxyState) {
    if (proxyState.isRunning) return _TrayStatus.connected;
    if (proxyState.lastError != null) return _TrayStatus.error;
    return _TrayStatus.disconnected;
  }

  Future<void> _applyIcon() async {
    final proxyState = _proxyState;
    if (proxyState == null) return;

    final status = _statusFor(proxyState);
    // ProxyState also notifies for every log line. Avoid repeatedly replacing
    // the native tray icon when the connection state has not changed.
    if (_appliedIconStatus == status) return;

    final (iconName, tooltipStatus) = switch (status) {
      _TrayStatus.connected => ('tray_icon', 'Connected'),
      _TrayStatus.disconnected => ('tray_icon_inactive', 'Disconnected'),
      _TrayStatus.error => ('tray_icon_error', 'Connection error'),
    };
    final iconPath = Platform.isWindows
        ? 'assets/tray/$iconName.ico'
        : 'assets/tray/$iconName.png';

    _appliedIconStatus = null;
    if (!await _call(() => trayManager.setIcon(iconPath), 'setIcon')) return;
    if (!await _call(
      () => trayManager.setToolTip('Proxy Everything - $tooltipStatus'),
      'setToolTip',
    )) {
      return;
    }
    _appliedIconStatus = status;
  }

  Future<void> _applyMenu() async {
    final proxyState = _proxyState;
    if (proxyState == null) return;

    final isRunning = proxyState.isRunning;
    final isBusy =
        proxyState.isProxyOperationInProgress || proxyState.isTunBusy;
    final config = proxyState.config;
    final status = _statusFor(proxyState);
    final menuSignature = Object.hash(
      _isWindowVisible,
      status,
      isBusy,
      config.serverHost,
      config.serverPort,
    );
    if (_appliedMenuSignature == menuSignature) return;

    final statusLabel = isBusy
        ? 'Proxy: Updating'
        : switch (status) {
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

    _appliedMenuSignature = null;
    if (!await _call(
      () => trayManager.setContextMenu(menu),
      'setContextMenu',
    )) {
      return;
    }
    _appliedMenuSignature = menuSignature;
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_toggleWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key != null) unawaited(_handleMenuClick(key));
  }

  Future<void> _popUpContextMenu() async {
    // The show/hide entry is the only place the cached visibility is visible to
    // the user, so reconcile it with the real window right before the menu is
    // drawn instead of polling on every proxy notification.
    await _refreshWindowVisibility();
    await _enqueue(_applyMenu);
    await _call(trayManager.popUpContextMenu, 'popUpContextMenu');
  }

  Future<void> _refreshWindowVisibility() async {
    try {
      setWindowVisible(await windowManager.isVisible());
    } catch (error) {
      debugPrint('Failed to read window visibility: $error');
    }
  }

  /// Records a visibility change made elsewhere (close-to-tray, activation from
  /// a second launch) so the tray menu keeps offering the right action.
  void setWindowVisible(bool visible) {
    if (_isWindowVisible == visible) return;
    _isWindowVisible = visible;
    unawaited(_enqueue(_applyMenu));
  }

  Future<void> showWindow() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
    setWindowVisible(true);
  }

  Future<void> hideWindow() async {
    await windowManager.hide();
    setWindowVisible(false);
  }

  Future<void> _toggleWindow() async {
    // A visible but backgrounded window should come forward instead of
    // disappearing, which is what a single cached flag used to do.
    final isVisible = await windowManager.isVisible();
    final isFocused = isVisible && await windowManager.isFocused();
    if (isVisible && isFocused) {
      await hideWindow();
    } else {
      await showWindow();
    }
  }

  Future<void> _handleMenuClick(String key) async {
    final proxyState = _proxyState;
    if (proxyState == null) return;

    switch (key) {
      case 'show_hide':
        await _toggleWindow();
        break;
      case 'start':
        await proxyState.start();
        break;
      case 'stop':
        proxyState.stop();
        break;
      case 'quit':
        await _quitApp();
        break;
    }
  }

  Future<void> _quitApp() async {
    final proxyState = _proxyState;
    _isDisposed = true;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    proxyState?.removeListener(_onProxyStateChanged);
    // Stopping releases the native system-proxy guard. `exit` skips Dart and
    // Rust teardown, so the system proxy would otherwise keep pointing at a
    // listener that no longer exists.
    if (proxyState != null && proxyState.isRunning) {
      proxyState.stop();
    }
    try {
      await trayManager.destroy();
    } catch (error) {
      debugPrint('Failed to remove the tray icon on quit: $error');
    }
    await WindowStateService.instance.saveNow();
    await proxyState?.flushDesktopLogs();
    exit(0);
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    trayManager.removeListener(this);
    _proxyState?.removeListener(_onProxyStateChanged);
    _proxyState = null;
    _initialized = false;
  }
}
