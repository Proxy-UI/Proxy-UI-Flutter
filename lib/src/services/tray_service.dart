import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../models/node_model.dart';
import '../providers/proxy_provider.dart';
import '../utils/toast_utils.dart';
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
  ///
  /// [bounded] applies the shared timeout. Pass false for a call that blocks
  /// for as long as the user takes, which is not the same thing as a call that
  /// has hung.
  Future<bool> _call(
    Future<void> Function() action,
    String name, {
    bool bounded = true,
  }) async {
    if (!_trayAvailable) return false;
    try {
      await (bounded ? action().timeout(_callTimeout) : action());
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
    // macOS gets its own set: a template image is black plus alpha, and the
    // system tints it to match the menu bar, inverting it while the item is
    // highlighted. The colour icons the other platforms use would be flattened
    // into one silhouette, so those carry the state in the badge shape instead.
    //
    // The 2x file is named directly because the plugin reads the asset with
    // rootBundle.load, which takes an exact key and never resolves a resolution
    // variant, then pins the image to 18pt.
    final iconPath = switch (defaultTargetPlatform) {
      TargetPlatform.windows => 'assets/tray/$iconName.ico',
      TargetPlatform.macOS => 'assets/tray/${iconName}_macos@2x.png',
      _ => 'assets/tray/$iconName.png',
    };

    _appliedIconStatus = null;
    if (!await _call(
      () => trayManager.setIcon(iconPath, isTemplate: Platform.isMacOS),
      'setIcon',
    )) {
      return;
    }
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
    final isTunRunning = proxyState.isTunRunning;
    final isBusy =
        proxyState.isProxyOperationInProgress || proxyState.isTunBusy;
    final config = proxyState.config;
    final status = _statusFor(proxyState);
    final nodes = _menuNodes(proxyState);
    final menuSignature = Object.hash(
      status,
      isBusy,
      isRunning,
      isTunRunning,
      config.serverHost,
      config.serverPort,
      proxyState.currentNodeId,
      proxyState.hasLocalLogStorage,
      Object.hashAll(nodes.map((node) => node.nodeId)),
    );
    if (_appliedMenuSignature == menuSignature) return;

    final statusLabel = isBusy
        ? 'Updating…'
        : switch (status) {
            _TrayStatus.connected =>
              isTunRunning ? 'Connected · TUN capturing' : 'Connected',
            _TrayStatus.disconnected => 'Disconnected',
            _TrayStatus.error => 'Connection error',
          };
    final serverLabel = '${config.serverHost}:${config.serverPort}';

    final menu = Menu(
      items: [
        // The two lines the tray exists to answer: is it on, and through what.
        MenuItem(key: 'status', label: statusLabel, disabled: true),
        MenuItem(key: 'server', label: serverLabel, disabled: true),
        MenuItem.separator(),
        // Checkboxes rather than a Start/Stop pair, one half of which was
        // always greyed out and told the user nothing about the current state.
        MenuItem.checkbox(
          key: 'proxy',
          label: 'Proxy',
          checked: isRunning,
          disabled: isBusy || config.serverHost.isEmpty,
        ),
        MenuItem.checkbox(
          key: 'tun',
          label: 'TUN mode',
          checked: isTunRunning,
          // TUN captures through the local listener, so it cannot outlive it.
          disabled: isBusy || !isRunning,
        ),
        if (nodes.isNotEmpty) ...[
          MenuItem.separator(),
          MenuItem.submenu(
            key: 'nodes',
            label: 'Switch node',
            disabled: isBusy,
            submenu: Menu(
              items: [
                for (final node in nodes)
                  MenuItem.checkbox(
                    key: 'node:${node.nodeId}',
                    label: _nodeLabel(node),
                    checked: proxyState.isCurrentNode(node),
                  ),
              ],
            ),
          ),
        ],
        MenuItem.separator(),
        MenuItem(key: 'show', label: 'Show window'),
        if (proxyState.hasLocalLogStorage)
          MenuItem(key: 'logs', label: 'Open log folder'),
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
    // Always raise. Toggling needed to know whether the window was already in
    // front, and the only signal for that — focus — is unreliable at exactly
    // the moment the tray is clicked, because the shell has just taken it.
    unawaited(showWindow());
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
    await _enqueue(_applyMenu);
    // `bringAppToFront` is the plugin's only way to reach the
    // `SetForegroundWindow` that Win32 requires before `TrackPopupMenu`:
    // without it the menu belongs to a window that is not in the foreground,
    // and Windows then leaves it on screen when the user clicks away or opens
    // something else. The flag is marked deprecated upstream but is still the
    // documented fix, and 0.5.3 is the newest release.
    //
    // Unbounded because `TrackPopupMenu` is modal: the call does not return
    // until the menu closes, so the shared timeout would fire on any menu a
    // person actually reads before choosing.
    await _call(
      // ignore: deprecated_member_use
      () => trayManager.popUpContextMenu(bringAppToFront: true),
      'popUpContextMenu',
      bounded: false,
    );
  }

  Future<void> showWindow() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();

    // macOS hides by ordering the window out, which also drops the app from the
    // foreground. A single show/focus pair sometimes lands while the shell still
    // owns activation — the click on the tray just gave it away — and the window
    // stays gone with no way back except relaunching. Confirm it really came
    // back and ask once more if it did not.
    if (!Platform.isMacOS) return;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (await windowManager.isVisible()) return;
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hideWindow() => windowManager.hide();

  /// Nodes worth offering in the menu.
  ///
  /// A context menu is a poor list widget, and a long server catalogue turns it
  /// into one. Anything past this belongs on the nodes page.
  static const int _maxMenuNodes = 12;

  List<NodeInfo> _menuNodes(ProxyState proxyState) {
    final nodes = proxyState.nodes;
    return nodes.length <= _maxMenuNodes
        ? nodes
        : nodes.take(_maxMenuNodes).toList(growable: false);
  }

  String _nodeLabel(NodeInfo node) {
    final name = node.displayName.trim();
    // `displayName` is "country - region" and geo lookup can leave both empty.
    final hasName = name.isNotEmpty && name != '-';
    final label = hasName ? '$name (${node.addr})' : node.addr;
    return node.latencyMs != null ? '$label · ${node.latencyDisplay}' : label;
  }

  Future<void> _handleMenuClick(String key) async {
    final proxyState = _proxyState;
    if (proxyState == null) return;

    if (key.startsWith('node:')) {
      await _switchNode(proxyState, key.substring('node:'.length));
      return;
    }

    switch (key) {
      case 'proxy':
        if (proxyState.isRunning) {
          await proxyState.stop();
        } else {
          final started = await proxyState.start();
          if (!started) {
            ToastUtils.showError(proxyState.lastError ?? 'Could not start');
          }
        }
        break;
      case 'tun':
        await _toggleTun(proxyState);
        break;
      case 'show':
        await showWindow();
        break;
      case 'logs':
        try {
          await proxyState.openLogDirectory();
        } catch (error) {
          ToastUtils.showError('Could not open the log folder: $error');
        }
        break;
      case 'quit':
        await _quitApp();
        break;
    }
  }

  Future<void> _toggleTun(ProxyState proxyState) async {
    final enable = !proxyState.isTunRunning;
    final result = await proxyState.setTunEnabled(enable);
    // Null means an unelevated Windows instance launched its elevated
    // replacement. This process has to release the port and go, exactly as the
    // proxy page does when the switch is used there.
    if (result == null) {
      ToastUtils.showInfo('Restarting with administrator privileges for TUN');
      proxyState.stopForElevationHandoff();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await proxyState.flushDesktopLogs();
      exit(0);
    }
    if (result == false) {
      ToastUtils.showError(proxyState.lastError ?? 'Failed to change TUN mode');
    }
  }

  Future<void> _switchNode(ProxyState proxyState, String nodeId) async {
    NodeInfo? target;
    for (final node in proxyState.nodes) {
      if (node.nodeId == nodeId) {
        target = node;
        break;
      }
    }
    if (target == null) return;
    if (proxyState.isCurrentNode(target)) return;

    try {
      final switched = await proxyState.switchToNode(target);
      if (switched) {
        ToastUtils.showSuccess('Switched to ${_nodeLabel(target)}');
      } else {
        ToastUtils.showError(proxyState.lastError ?? 'Could not switch node');
      }
    } catch (error) {
      ToastUtils.showError('Could not switch node: $error');
    }
  }

  Future<void> _quitApp() async {
    final proxyState = _proxyState;
    _isDisposed = true;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    proxyState?.removeListener(_onProxyStateChanged);
    // Stopping releases the native system-proxy guard and, on macOS, waits for
    // the privileged helper to put the system routes and DNS back. `exit` below
    // skips Dart and Rust teardown, so without awaiting this the machine can be
    // left pointing at a proxy listener and a tunnel resolver that are both gone.
    // `stop` also covers a TUN session that outlived the listener.
    if (proxyState != null &&
        (proxyState.isRunning || proxyState.isTunRunning)) {
      await proxyState.stop();
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
