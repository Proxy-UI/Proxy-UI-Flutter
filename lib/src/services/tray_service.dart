import 'app_brand.dart';
import 'build_capabilities.dart';
import 'elevation_handoff.dart';

import 'package:proxy_ui/l10n/app_language.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart'
    show
        ContextMenuTrigger,
        Image,
        ImageAsset,
        ListenerId,
        Menu,
        MenuClosedEvent,
        MenuItem,
        MenuItemClickedEvent,
        MenuItemState,
        MenuItemType,
        MenuOpenedEvent,
        TrayIcon,
        TrayIconClickedEvent,
        TrayManager;
import 'package:window_manager/window_manager.dart';

import '../models/node_model.dart';
import '../models/upstream_endpoint.dart';
import '../providers/proxy_provider.dart';
import '../utils/toast_utils.dart';
import 'window_state_service.dart';

enum _TrayStatus { connected, disconnected, error }

/// Owns the desktop notification icon and keeps it consistent with
/// [ProxyState].
///
/// nativeapi applies every tray call synchronously on the calling isolate, so
/// updates cannot overlap and need no queue of their own.
class TrayService {
  static TrayService? _instance;
  ProxyState? _proxyState;
  bool _initialized = false;
  bool _isDisposed = false;
  bool _isShutDown = false;

  /// Kept for as long as the icon should be shown: nativeapi releases a handle
  /// when its Dart wrapper is collected, and that removes the icon.
  TrayIcon? _trayIcon;
  ListenerId? _trayIconListener;
  Image? _iconImage;
  _TrayMenu? _menu;

  /// The context menu is on screen. The native menu loop keeps using its
  /// handles until it closes, so a menu is never replaced or freed while open:
  /// a rebuild that falls due meanwhile waits for the close.
  bool _menuOpen = false;
  bool _menuRebuildPending = false;
  bool _iconRebuildPending = false;

  /// State the shell has actually accepted. Both are cleared before a platform
  /// call and only restored after it succeeds, so a failed call can never leave
  /// the tray frozen on a stale icon or menu.
  _TrayStatus? _appliedIconStatus;
  String? _appliedIconLanguage;
  int? _appliedMenuSignature;

  /// Catches the case no event reports: the shell dropping the icon while the
  /// app has nothing to react to. Re-asserting the icon's visibility adds it
  /// back when the shell has dropped it, and costs nothing otherwise. The menu
  /// belongs to the app, so it is not part of this.
  Timer? _healthCheckTimer;
  static const Duration _healthCheckInterval = Duration(seconds: 20);

  TrayService._();

  static TrayService get instance {
    _instance ??= TrayService._();
    return _instance!;
  }

  void initialize(ProxyState proxyState) {
    if (_initialized || _isShutDown) return;
    if (!TrayManager.instance.isSupported()) {
      debugPrint('No system tray on this desktop; tray stays off');
      return;
    }
    _initialized = true;
    _isDisposed = false;

    _proxyState = proxyState;
    proxyState.addListener(_applyTray);
    AppLanguage.instance.addListener(_onLanguageChanged);

    _applyTray();
    _startHealthCheck();
  }

  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(_healthCheckInterval, (_) {
      if (_isDisposed) return;
      _appliedIconStatus = null;
      _applyIcon();
    });
  }

  /// Recreates the icon after the machine wakes up.
  ///
  /// Resume is the one moment where the shell is most likely to have dropped
  /// the icon, and a plain re-assert cannot bring back an icon that is gone —
  /// only a delete and re-add can.
  void handleSystemResume() {
    if (_isDisposed || !_initialized) return;
    rebuild();
  }

  /// Deletes and re-adds the notification icon.
  ///
  /// `NIM_MODIFY` silently fails once the shell has dropped an icon, so a
  /// disappeared icon can only be recovered by adding it again.
  void rebuild() {
    if (_isDisposed || !_initialized) return;
    if (_menuOpen) {
      _iconRebuildPending = true;
      return;
    }
    _destroyTrayIcon();
    _applyTray();
  }

  void _onLanguageChanged() {
    _appliedMenuSignature = null;
    _appliedIconStatus = null;
    _applyTray();
  }

  void _applyTray() {
    if (_isDisposed) return;
    _applyIcon();
    _applyMenu();
  }

  /// The icon, created on first use. Null when the platform refused one; the
  /// next update asks again.
  TrayIcon? _ensureTrayIcon() {
    final existing = _trayIcon;
    if (existing != null) return existing;
    final trayIcon = TrayIcon.create();
    if (trayIcon == null) {
      debugPrint('Could not create the tray icon');
      return null;
    }
    _trayIconListener = trayIcon.addListener((event) {
      // Always raise. Toggling needed to know whether the window was already
      // in front, and the only signal for that — focus — is unreliable at
      // exactly the moment the tray is clicked, because the shell has just
      // taken it.
      if (event is TrayIconClickedEvent && !_isDisposed) {
        unawaited(showWindow());
      }
    });
    // The menu opens natively at the cursor. Linux panels never report clicks
    // and open the menu themselves.
    trayIcon
      ..setContextMenuTrigger(ContextMenuTrigger.rightClicked)
      ..setVisible(true);
    _trayIcon = trayIcon;
    return trayIcon;
  }

  void _destroyTrayIcon() {
    final trayIcon = _trayIcon;
    _trayIcon = null;
    _appliedIconStatus = null;
    _appliedMenuSignature = null;
    if (trayIcon != null) {
      final listener = _trayIconListener;
      if (listener != null) trayIcon.removeListener(listener);
      trayIcon.dispose();
    }
    _trayIconListener = null;
    _iconImage?.dispose();
    _iconImage = null;
    // An exit that follows must not find handles still alive (see [shutdown]).
    _menu?.dispose();
    _menu = null;
    _menuOpen = false;
    _menuRebuildPending = false;
    _iconRebuildPending = false;
  }

  _TrayStatus _statusFor(ProxyState proxyState) {
    if (proxyState.isRunning) return _TrayStatus.connected;
    if (proxyState.lastError != null) return _TrayStatus.error;
    return _TrayStatus.disconnected;
  }

  void _applyIcon() {
    final proxyState = _proxyState;
    if (proxyState == null) return;

    final status = _statusFor(proxyState);
    // ProxyState also notifies for every log line. Avoid repeatedly replacing
    // the native tray icon when the connection state has not changed.
    final language = AppLanguage.instance.locale.languageCode;
    if (_appliedIconStatus == status && _appliedIconLanguage == language) {
      return;
    }

    final (iconName, tooltipStatus) = switch (status) {
      _TrayStatus.connected => ('tray_icon', appStrings.connected),
      _TrayStatus.disconnected => (
        'tray_icon_inactive',
        appStrings.disconnected,
      ),
      _TrayStatus.error => ('tray_icon_error', appStrings.connectionError),
    };
    // macOS gets its own set: a template image is black plus alpha, and the
    // system tints it to match the menu bar, inverting it while the item is
    // highlighted. The colour icons the other platforms use would be flattened
    // into one silhouette, so those carry the state in the badge shape instead.
    //
    // The 2x file is named directly because ImageAsset reads the bundled file
    // by its exact name and never resolves a resolution variant; nativeapi
    // then draws the image at 18pt.
    final iconPath = switch (defaultTargetPlatform) {
      TargetPlatform.windows => 'assets/tray/$iconName.ico',
      TargetPlatform.macOS => 'assets/tray/${iconName}_macos@2x.png',
      _ => 'assets/tray/$iconName.png',
    };

    _appliedIconStatus = null;
    final trayIcon = _ensureTrayIcon();
    if (trayIcon == null) return;
    final image = ImageAsset.fromAsset(iconPath);
    if (image == null) {
      debugPrint('Could not load the tray icon $iconPath');
      return;
    }
    trayIcon
      ..isIconTemplate = Platform.isMacOS
      ..icon = image
      ..setTooltip('${AppBrand.name} - $tooltipStatus')
      // Updates above only reach an icon the shell still has; this adds it
      // back if the shell dropped it.
      ..setVisible(true);
    _iconImage?.dispose();
    _iconImage = image;
    _appliedIconStatus = status;
    _appliedIconLanguage = language;
  }

  void _applyMenu() {
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
      AppLanguage.instance.locale.languageCode,
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
        ? appStrings.updating
        : switch (status) {
            _TrayStatus.connected =>
              isTunRunning
                  ? appStrings.connectedTunCapturing
                  : appStrings.connected,
            _TrayStatus.disconnected => appStrings.disconnected,
            _TrayStatus.error => appStrings.connectionError,
          };
    final serverLabel = endpointLabel(config.serverHost, config.serverPort);

    final entries = [
      // The two lines the tray exists to answer: is it on, and through what.
      _MenuEntry.info(statusLabel),
      _MenuEntry.info(serverLabel),
      const _MenuEntry.separator(),
      // Checkboxes rather than a Start/Stop pair, one half of which was
      // always greyed out and told the user nothing about the current state.
      _MenuEntry(
        'proxy',
        appStrings.proxy,
        checked: isRunning,
        enabled: !isBusy && config.serverHost.isNotEmpty,
      ),
      if (!BuildCapabilities.isMacAppStore)
        _MenuEntry(
          'tun',
          appStrings.tunMode2,
          checked: isTunRunning,
          // TUN captures through the local listener, so it cannot outlive it.
          enabled: !isBusy && isRunning,
        ),
      if (nodes.isNotEmpty) ...[
        const _MenuEntry.separator(),
        _MenuEntry.submenu(appStrings.switchNode, enabled: !isBusy, [
          for (final node in nodes)
            _MenuEntry(
              'node:${node.nodeId}',
              _nodeLabel(node),
              checked: proxyState.isCurrentNode(node),
            ),
        ]),
      ],
      const _MenuEntry.separator(),
      _MenuEntry('show', appStrings.showWindow),
      if (proxyState.hasLocalLogStorage)
        _MenuEntry('logs', appStrings.openLogFolder),
      const _MenuEntry.separator(),
      _MenuEntry('quit', appStrings.quit),
    ];

    _appliedMenuSignature = null;
    final trayIcon = _ensureTrayIcon();
    if (trayIcon == null) return;
    final current = _menu;
    if (current != null &&
        current.structure == _TrayMenu.structureOf(entries)) {
      // Labels, check marks and enabled states change in place, which is safe
      // while the menu is on screen.
      current.update(entries);
    } else if (_menuOpen) {
      _menuRebuildPending = true;
      return;
    } else {
      final menu = _TrayMenu.build(
        entries,
        onClick: _onMenuClick,
        onOpenChanged: _onMenuOpenChanged,
      );
      if (menu == null) {
        debugPrint('Could not create the tray menu');
        return;
      }
      trayIcon.setContextMenu(menu.root);
      // Item clicks reach Dart asynchronously, after the native callback has
      // returned, so the replaced menu can be freed even from a click handler.
      current?.dispose();
      _menu = menu;
    }
    _appliedMenuSignature = menuSignature;
  }

  void _onMenuOpenChanged(_TrayMenu menu, bool open) {
    if (!identical(menu, _menu)) return;
    _menuOpen = open;
    if (open || _isDisposed) return;
    if (_iconRebuildPending) {
      _iconRebuildPending = false;
      _menuRebuildPending = false;
      rebuild();
    } else if (_menuRebuildPending) {
      _menuRebuildPending = false;
      _applyMenu();
    }
  }

  void _onMenuClick(String key) => unawaited(_handleMenuClick(key));

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

  /// Once tray teardown starts, closing must retry Quit and minimizing must
  /// keep the window reachable, even if native destroy completes much later.
  bool get needsExitRetry => _isDisposed;

  Future<void> hideWindow() async {
    if (!_isDisposed) await windowManager.hide();
    // Recheck after the platform call: shutdown may have begun while hiding.
    if (_isDisposed) await showWindow();
  }

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
    final address = node.endpoint?.label ?? node.addr;
    final label = hasName ? '$name ($address)' : address;
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
            ToastUtils.showError(
              proxyState.lastError ?? appStrings.couldNotStart,
            );
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
          ToastUtils.showError(
            appStrings.couldNotOpenTheLogFolder((error).toString()),
          );
        }
        break;
      case 'quit':
        await quit(proxyState);
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
      ToastUtils.showInfo(
        appStrings.restartingWithAdministratorPrivilegesForTun,
      );
      await finishElevationHandoff(proxyState);
      return;
    }
    if (result == false) {
      ToastUtils.showError(
        proxyState.lastError ?? appStrings.failedToChangeTunMode,
      );
    }
  }

  /// The elevated child waits for this process's single-instance lock. Release
  /// native resources before exit, while their Windows dependencies are alive.
  Future<void> finishElevationHandoff(ProxyState proxyState) async {
    try {
      if (!await prepareElevationExit(
        stopProxy: proxyState.stopForElevationHandoff,
        releaseTray: shutdown,
        flushLogs: proxyState.flushDesktopLogs,
      )) {
        await showWindow();
        ToastUtils.showError(
          proxyState.lastError ?? appStrings.failedToStopProxy,
        );
        return;
      }
    } catch (error) {
      await showWindow();
      ToastUtils.showError(
        '${appStrings.shutdownFailedRetryFromWindow}\n$error',
      );
      return;
    }
    exit(0);
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
        ToastUtils.showSuccess(
          appStrings.switchedTo((_nodeLabel(target)).toString()),
        );
      } else {
        ToastUtils.showError(
          proxyState.lastError ?? appStrings.couldNotSwitchNode,
        );
      }
    } catch (error) {
      ToastUtils.showError(appStrings.couldNotSwitchNode2((error).toString()));
    }
  }

  Future<void> quit(ProxyState proxyState) async {
    // Stopping releases the native system-proxy guard and, on macOS, waits for
    // the privileged helper to put the system routes and DNS back. `exit` below
    // skips Dart and Rust teardown, so without awaiting this the machine can be
    // left pointing at a proxy listener and a tunnel resolver that are both gone.
    // `stop` also covers a TUN session that outlived the listener.
    if (!await proxyState.stop()) {
      await showWindow();
      ToastUtils.showError(
        proxyState.lastError ?? appStrings.failedToStopProxy,
      );
      return;
    }
    await shutdown();
    await WindowStateService.instance.saveNow();
    await proxyState.flushDesktopLogs();
    exit(0);
  }

  /// Stop updates and explicitly free the native tray.
  /// cnativeapi 0.5.2 destroys its taskbar callback table before retained tray
  /// handles during ExitProcess; leaving the tray alive causes an access
  /// violation in TrayIcon::Impl's destructor. Dart finalizers cannot fix that
  /// ordering after exit has begun.
  Future<void> shutdown() async {
    _isShutDown = true;
    dispose();
    _destroyTrayIcon();
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _proxyState?.removeListener(_applyTray);
    AppLanguage.instance.removeListener(_onLanguageChanged);
    _proxyState = null;
    _initialized = false;
  }
}

/// One line of the tray menu, described before any native object exists.
class _MenuEntry {
  /// A clickable line; a non-null [checked] makes it a checkbox.
  const _MenuEntry(this.key, this.label, {this.checked, this.enabled = true})
    : children = const [];

  /// A line that only reports state.
  const _MenuEntry.info(this.label)
    : key = null,
      checked = null,
      enabled = false,
      children = const [];

  const _MenuEntry.submenu(this.label, this.children, {this.enabled = true})
    : key = null,
      checked = null;

  const _MenuEntry.separator()
    : key = null,
      label = null,
      checked = null,
      enabled = false,
      children = const [];

  final String? key;

  /// Null for a separator.
  final String? label;
  final bool? checked;
  final bool enabled;
  final List<_MenuEntry> children;
}

/// A native menu item, with the check state the menu should show.
class _ItemBinding {
  _ItemBinding(this.item, this.checked);

  final MenuItem item;
  bool? checked;
  ListenerId? listener;
}

/// A native context menu and every wrapper it depends on.
///
/// nativeapi frees a handle when its Dart wrapper is collected, and a click
/// listener lasts only as long as the item it was added to, so the whole tree
/// is held here until the menu is replaced.
class _TrayMenu {
  _TrayMenu._(this.structure);

  /// The kind and key of every line, in order. Two menus with the same
  /// structure differ only in what [update] changes in place.
  final String structure;
  final List<Menu> _menus = [];
  final List<_ItemBinding> _items = [];
  late final Menu root;
  ListenerId? _rootListener;

  static String structureOf(List<_MenuEntry> entries) {
    final out = StringBuffer();
    void visit(List<_MenuEntry> level) {
      for (final entry in level) {
        if (entry.label == null) {
          out.write('-');
        } else {
          out
            ..write(entry.key ?? '')
            ..write(entry.checked == null ? '' : '?');
          if (entry.children.isNotEmpty) {
            out.write('[');
            visit(entry.children);
            out.write(']');
          }
        }
        out.write('\n');
      }
    }

    visit(entries);
    return out.toString();
  }

  /// Null when the platform refused to create part of the menu.
  static _TrayMenu? build(
    List<_MenuEntry> entries, {
    required void Function(String key) onClick,
    required void Function(_TrayMenu menu, bool open) onOpenChanged,
  }) {
    final menu = _TrayMenu._(structureOf(entries));
    final root = menu._build(entries, onClick);
    if (root == null) {
      menu.dispose();
      return null;
    }
    menu.root = root;
    menu._rootListener = root.addListener((event) {
      if (event is MenuOpenedEvent) onOpenChanged(menu, true);
      if (event is MenuClosedEvent) onOpenChanged(menu, false);
    });
    return menu;
  }

  /// Items are recorded in pre-order, the order [update] walks the entries.
  Menu? _build(List<_MenuEntry> entries, void Function(String key) onClick) {
    final menu = Menu.create();
    if (menu == null) return null;
    _menus.add(menu);

    for (final entry in entries) {
      final label = entry.label;
      if (label == null) {
        menu.addSeparator();
        continue;
      }
      final checked = entry.checked;
      final type = entry.children.isNotEmpty
          ? MenuItemType.submenu
          : checked != null
          ? MenuItemType.checkbox
          : MenuItemType.normal;
      final item = MenuItem.createWithLabelAndType(label, type);
      if (item == null) return null;
      final binding = _ItemBinding(item, checked);
      _items.add(binding);
      item.isEnabled = entry.enabled;
      if (checked != null) item.state = _stateOf(checked);
      if (entry.children.isNotEmpty) {
        final submenu = _build(entry.children, onClick);
        if (submenu == null) return null;
        item.submenu = submenu;
      }

      final key = entry.key;
      if (key != null) {
        binding.listener = item.addListener((event) {
          if (event is! MenuItemClickedEvent) return;
          // GTK ticks a check item by itself when it is clicked. The menu
          // shows the state, not the request; an update follows the change.
          final shown = binding.checked;
          if (shown != null) item.state = _stateOf(shown);
          onClick(key);
        });
      }
      menu.addItem(item);
    }
    return menu;
  }

  /// Applies labels, enabled states and check marks of `entries`, which must
  /// have this menu's [structure].
  void update(List<_MenuEntry> entries) {
    var index = 0;
    void visit(List<_MenuEntry> level) {
      for (final entry in level) {
        final label = entry.label;
        if (label == null) continue;
        final binding = _items[index++];
        binding.item
          ..label = label
          ..isEnabled = entry.enabled;
        final checked = entry.checked;
        if (checked != null) {
          binding.checked = checked;
          binding.item.state = _stateOf(checked);
        }
        visit(entry.children);
      }
    }

    visit(entries);
  }

  static MenuItemState _stateOf(bool checked) =>
      checked ? MenuItemState.checked : MenuItemState.unchecked;

  void dispose() {
    final rootListener = _rootListener;
    if (rootListener != null) root.removeListener(rootListener);
    _rootListener = null;
    for (final binding in _items) {
      final listener = binding.listener;
      if (listener != null) binding.item.removeListener(listener);
      binding.item.dispose();
    }
    _items.clear();
    for (final menu in _menus) {
      menu.dispose();
    }
    _menus.clear();
  }
}
