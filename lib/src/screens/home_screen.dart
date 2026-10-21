import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../providers/proxy_provider.dart';
import '../services/app_brand.dart';
import '../services/build_capabilities.dart';
import '../services/proxy_launcher_service.dart';
import '../widgets/app_window_title_bar.dart';
import '../updates/update_dialog.dart';
import '../widgets/appearance_controls.dart';
import 'dashboard_page.dart';
import 'log_page.dart';
import 'launcher_page.dart';
import 'nodes/nodes_page.dart';
import 'store_demo_screen.dart';
import 'store_privacy_screen.dart';
import 'subscription_page.dart';

enum _Destination { proxy, nodes, logs, launchers, subscription }

/// The application shell: a navigation rail beside the page on wide
/// windows, a navigation bar beneath it on phones, and a power control that
/// is always one click away.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  _Destination _current = _Destination.proxy;
  String? _nodesSelection;

  /// Below this width the rail gives way to a bottom navigation bar.
  static const double _compactWidth = 640;

  List<_Destination> get _destinations => [
    _Destination.proxy,
    _Destination.nodes,
    _Destination.logs,
    if (ProxyLauncherService.isSupported) _Destination.launchers,
    if (!BuildCapabilities.usesPacketTunnel) _Destination.subscription,
  ];

  void _go(_Destination destination, {String? selection}) {
    setState(() {
      _current = destination;
      _nodesSelection = selection;
    });
  }

  ({IconData icon, IconData selected, String label}) _describe(
    _Destination destination,
  ) => switch (destination) {
    _Destination.proxy => (
      icon: Icons.space_dashboard_outlined,
      selected: Icons.space_dashboard,
      label: context.l10n.proxy,
    ),
    _Destination.nodes => (
      icon: Icons.hub_outlined,
      selected: Icons.hub,
      label: context.l10n.nodes,
    ),
    _Destination.logs => (
      icon: Icons.terminal_outlined,
      selected: Icons.terminal,
      label: context.l10n.logs,
    ),
    _Destination.subscription => (
      icon: Icons.cloud_download_outlined,
      selected: Icons.cloud_download,
      label: context.l10n.subscription,
    ),
    _Destination.launchers => (
      icon: Icons.apps_outlined,
      selected: Icons.apps,
      label: context.l10n.appLaunchers,
    ),
  };

  Widget _page() => switch (_current) {
    _Destination.proxy => DashboardPage(
      onOpenNodes: (selection) => _go(_Destination.nodes, selection: selection),
    ),
    _Destination.nodes => NodesPage(initialSelection: _nodesSelection),
    _Destination.logs => const LogPage(),
    _Destination.launchers => LauncherPage(
      defaultPort: context.select<ProxyState, int>(
        (state) => state.config.localPort,
      ),
    ),
    _Destination.subscription => const SubscriptionPage(),
  };

  PreferredSizeWidget _appBar() {
    // Every preference about how the app looks lives here, on every layout;
    // the navigation only navigates.
    final actions = [
      if (BuildCapabilities.isMacAppStore) const StoreDemoButton(compact: true),
      if (BuildCapabilities.isMacAppStore) const StorePrivacyButton(),
      const UpdateButton(),
      const LanguageMenuButton(),
      const ColorSeedMenu(),
      const ThemeToggle(),
    ];
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return AppWindowTitleBar(title: AppBrand.name, actions: actions);
    }
    final scheme = Theme.of(context).colorScheme;
    return AppBar(
      title: Text(AppBrand.name),
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      actions: actions,
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < _compactWidth;
    final destinations = _destinations;
    final index = destinations.indexOf(_current);
    final body = AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      // Pages fill the body; the default centring would shrink a scrolling
      // page to its content and float it in the middle.
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.985, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(_current), child: _page()),
    );
    return Scaffold(
      appBar: _appBar(),
      body: compact
          ? body
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (i) => _go(destinations[i]),
                  labelType: NavigationRailLabelType.all,
                  minWidth: 84,
                  leading: const SizedBox(height: 8),
                  destinations: [
                    for (final destination in destinations)
                      NavigationRailDestination(
                        icon: Icon(_describe(destination).icon),
                        selectedIcon: Icon(_describe(destination).selected),
                        label: Text(_describe(destination).label),
                      ),
                  ],
                ),
                Expanded(child: ClipRect(child: body)),
              ],
            ),
      bottomNavigationBar: compact
          ? NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) => _go(destinations[i]),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                for (final destination in destinations)
                  NavigationDestination(
                    icon: Icon(_describe(destination).icon),
                    selectedIcon: Icon(_describe(destination).selected),
                    label: _describe(destination).label,
                  ),
              ],
            )
          : null,
    );
  }
}
