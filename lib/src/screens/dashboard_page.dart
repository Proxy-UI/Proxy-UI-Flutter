import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../providers/proxy_provider.dart';
import '../services/build_capabilities.dart';
import '../widgets/lan_proxy_link.dart';
import '../widgets/node_badges.dart';
import 'nodes/control_server_dialog.dart';
import 'nodes/galaxy/galaxy_model.dart';
import 'nodes/node_actions.dart';
import 'nodes/node_details_panel.dart';
import 'proxy_controls.dart';

/// The connection at a glance: one control panel and the countries.
///
/// The panel holds the power control, the node in use, traffic capture and
/// the local proxy, one row each. Beside it every country with nodes is a
/// small badge; clicking one opens it on the node map.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.onOpenNodes});

  /// Open the node map, selecting [selection] when given.
  final void Function(String? selection) onOpenNodes;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProxyState>();
    final scene = buildGalaxyScene(
      galaxyNodesOf(state),
      connected: state.isRunning,
    );
    Widget countries({required bool scrolls}) => _CountryOverview(
      scene: scene,
      loaded: state.nodes.isNotEmpty,
      onOpenNodes: onOpenNodes,
      scrolls: scrolls,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          final width = (constraints.maxWidth * 0.34).clamp(380.0, 460.0);
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: width,
                  child: _ControlPanel(
                    state: state,
                    scene: scene,
                    onOpenNodes: onOpenNodes,
                    fill: true,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: countries(scrolls: true)),
              ],
            ),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ControlPanel(
                state: state,
                scene: scene,
                onOpenNodes: onOpenNodes,
                fill: false,
              ),
              const SizedBox(height: 12),
              countries(scrolls: false),
            ],
          ),
        );
      },
    );
  }
}

/// Everything the user controls, on one flat surface.
class _ControlPanel extends StatelessWidget {
  const _ControlPanel({
    required this.state,
    required this.scene,
    required this.onOpenNodes,
    required this.fill,
  });

  final ProxyState state;
  final GalaxyScene scene;
  final void Function(String? selection) onOpenNodes;

  /// Whether the panel has a height to fill: the power control then takes
  /// the free space above the rows.
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final power = _PowerSection(state: state);
    final rows = [
      _CurrentNodeRow(scene: scene, onOpenNodes: onOpenNodes),
      const Divider(height: 1, indent: 20, endIndent: 20),
      _CaptureRow(state: state),
      const Divider(height: 1, indent: 20, endIndent: 20),
      _LocalProxyRow(state: state),
      const SizedBox(height: 8),
    ];
    return Card(
      key: const Key('control-panel'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: fill
          ? LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: Center(child: power)),
                        ...rows,
                      ],
                    ),
                  ),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [power, ...rows],
            ),
    );
  }
}

/// The power control and what the connection is.
class _PowerSection extends StatelessWidget {
  const _PowerSection({required this.state});

  final ProxyState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = state.isRunning;
    final busy = state.isProxyOperationInProgress || state.isTunBusy;
    final endpoint = state.config.serverHost.isEmpty
        ? context.l10n.configureAServerToGetStarted
        : '${state.config.serverHost}:${state.config.serverPort}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PowerButton(state: state, size: 132),
          const SizedBox(height: 16),
          Text(
            busy
                ? context.l10n.working
                : running
                ? context.l10n.connected
                : context.l10n.disconnected,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: running ? scheme.primary : scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            endpoint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            connectionModeLabel(context, state),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The one control that starts and stops everything, with a halo that
/// breathes while traffic flows.
class _PowerButton extends StatefulWidget {
  const _PowerButton({required this.state, required this.size});

  final ProxyState state;
  final double size;

  @override
  State<_PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<_PowerButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _halo = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_PowerButton old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Breathe only while traffic flows, and never under reduced motion.
  void _sync() {
    final animate =
        (widget.state.isRunning || widget.state.isProxyOperationInProgress) &&
        !MediaQuery.disableAnimationsOf(context);
    if (animate && !_halo.isAnimating) {
      _halo.repeat();
    } else if (!animate && _halo.isAnimating) {
      _halo
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _halo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = widget.state;
    final running = state.isRunning;
    final busy = state.isProxyOperationInProgress || state.isTunBusy;
    final still = MediaQuery.disableAnimationsOf(context);
    final size = widget.size;
    final label = running
        ? context.l10n.tapToDisconnect
        : context.l10n.tapToConnect;
    return Semantics(
      button: true,
      toggled: running,
      label: label,
      child: Tooltip(
        message: label,
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (running && !still)
                AnimatedBuilder(
                  animation: _halo,
                  builder: (context, _) {
                    final t = _halo.value;
                    return Container(
                      width: size * (0.78 + t * 0.22),
                      height: size * (0.78 + t * 0.22),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: scheme.primary.withValues(
                            alpha: (1 - t) * 0.5,
                          ),
                          width: 2,
                        ),
                      ),
                    );
                  },
                ),
              SizedBox.square(
                dimension: size * 0.74,
                child: FilledButton(
                  key: const Key('power-button'),
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                    elevation: running ? 3 : 0,
                    backgroundColor: running
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    foregroundColor: running
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                  onPressed: canToggleProxy(state)
                      ? () => toggleProxy(context)
                      : null,
                  child: busy
                      ? SizedBox.square(
                          dimension: size * 0.24,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: running ? scheme.onPrimary : scheme.primary,
                          ),
                        )
                      : Icon(Icons.power_settings_new, size: size * 0.32),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row of the panel: an icon, a title over a line of detail, and the
/// row's own controls.
class _PanelRow extends StatelessWidget {
  const _PanelRow({
    super.key,
    required this.leading,
    required this.title,
    required this.detail,
    this.trailing = const [],
    this.onTap,
    this.detailColor,
  });

  final Widget leading;
  final String title;
  final String detail;
  final List<Widget> trailing;
  final VoidCallback? onTap;
  final Color? detailColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          SizedBox.square(dimension: 32, child: Center(child: leading)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: detailColor ?? scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// The node traffic goes through; opens it on the node map.
class _CurrentNodeRow extends StatelessWidget {
  const _CurrentNodeRow({required this.scene, required this.onOpenNodes});

  final GalaxyScene scene;
  final void Function(String? selection) onOpenNodes;

  @override
  Widget build(BuildContext context) {
    final current = scene.current;
    return _PanelRow(
      key: const Key('current-node'),
      onTap: () => onOpenNodes(current?.planet.id),
      leading: CountryFlagBadge(code: current?.system.code ?? '', size: 30),
      title: current == null
          ? context.l10n.currentNodeTitle
          : placeName(context, current.system.code),
      detail: current == null
          ? context.l10n.noCurrentNode
          : current.planet.node.node.addr,
      trailing: [
        if (current != null)
          HealthChip(
            health: current.planet.node.health,
            latencyMs: current.planet.node.latencyMs,
          ),
        Icon(
          Icons.chevron_right,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ],
    );
  }
}

/// Traffic capture: TUN on desktop, the platform VPN on Android and in the
/// App Store build.
class _CaptureRow extends StatelessWidget {
  const _CaptureRow({required this.state});

  final ProxyState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _PanelRow(
      key: const Key('capture-row'),
      leading: Icon(
        state.isTunRunning ? Icons.shield : Icons.shield_outlined,
        color: state.isTunRunning ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: captureIsVpn ? context.l10n.vpnService : context.l10n.tunMode,
      detail: captureStatusLabel(context, state),
      detailColor: state.isTunRunning ? scheme.primary : null,
      trailing: [
        if (supportsTunProcessBypass)
          IconButton(
            onPressed: () => showTunProcessDialog(context),
            icon: const Icon(Icons.security_outlined),
            tooltip: context.l10n.tunBypassProcesses(
              state.config.tunBypassProcesses.length.toString(),
            ),
          ),
        if (Platform.isMacOS && !BuildCapabilities.isMacAppStore)
          IconButton(
            onPressed: state.isTunBusy
                ? null
                : () => showTunDiagnostics(context),
            icon: const Icon(Icons.help_outline),
            tooltip: context.l10n.tunDiagnosticsGuide,
          ),
        if (Platform.isAndroid)
          IconButton(
            onPressed: () => showAndroidVpnAppDialog(context),
            icon: const Icon(Icons.apps_outlined),
            tooltip: context.l10n.vpnApplications(
              state.config.androidVpnPackages.length.toString(),
            ),
          ),
        if (state.isTunBusy)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (!BuildCapabilities.isMacAppStore)
          Switch(
            value: state.isTunRunning,
            onChanged: state.isRunning
                ? (enabled) => toggleTun(context, enabled)
                : null,
          ),
      ],
    );
  }
}

/// Where the local proxy listens, and its configuration.
class _LocalProxyRow extends StatelessWidget {
  const _LocalProxyRow({required this.state});

  final ProxyState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final host = state.config.allowLan ? '0.0.0.0' : '127.0.0.1';
    final row = _PanelRow(
      key: const Key('local-proxy-row'),
      leading: Icon(Icons.settings_ethernet, color: scheme.onSurfaceVariant),
      title: context.l10n.localProxy,
      detail: 'socks5://$host:${state.config.localPort}',
      trailing: [
        TextButton(
          onPressed: () => showConfigDialog(context),
          child: Text(context.l10n.config),
        ),
        MenuAnchor(
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.content_paste_go),
              onPressed: () => importConfigFromClipboard(context),
              child: Text(context.l10n.importFromClipboard),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.ios_share),
              onPressed: () => exportConfigToClipboard(context),
              child: Text(context.l10n.exportToClipboard),
            ),
          ],
          builder: (context, controller, _) => IconButton(
            tooltip: context.l10n.options,
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.more_vert),
          ),
        ),
      ],
    );
    if (!state.config.allowLan) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: LanProxyLink(port: state.config.localPort),
        ),
      ],
    );
  }
}

/// Every country with nodes, as a small badge each: its flag inside the
/// status ring its star wears in the galaxy. A click opens that country on
/// the node map.
class _CountryOverview extends StatelessWidget {
  const _CountryOverview({
    required this.scene,
    required this.loaded,
    required this.onOpenNodes,
    required this.scrolls,
  });

  final GalaxyScene scene;
  final bool loaded;
  final void Function(String? selection) onOpenNodes;

  /// Whether the grid scrolls inside a fixed height, rather than growing
  /// with its content inside a scrolling page.
  final bool scrolls;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = scene.planets.length;
    final available = scene.planets
        .where((planet) => planet.node.health.isAvailable)
        .length;
    final systems = [...scene.systems]
      ..sort((a, b) {
        if (a.unknown != b.unknown) return a.unknown ? 1 : -1;
        return b.planets.length.compareTo(a.planets.length);
      });
    final regions = systems.where((system) => !system.unknown).length;
    final currentSystem = scene.current?.system.id;
    final grid = GridView.builder(
      shrinkWrap: !scrolls,
      physics: scrolls ? null : const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 168,
        mainAxisExtent: 156,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: systems.length,
      itemBuilder: (context, index) => _CountryTile(
        system: systems[index],
        current: systems[index].id == currentSystem,
        onTap: () => onOpenNodes(systems[index].id),
      ),
    );
    return Card(
      key: const Key('country-overview'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: scrolls ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.nodes,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (total > 0)
                        Text(
                          context.l10n.nodeMapSummary(
                            regions,
                            available,
                            total,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('open-node-map'),
                  tooltip: context.l10n.openNodeMap,
                  onPressed: () => onOpenNodes(null),
                  icon: const Icon(Icons.blur_circular),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (!loaded)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: FilledButton.icon(
                    onPressed: () => ControlServerDialog.show(context),
                    icon: const Icon(Icons.hub_outlined),
                    label: Text(context.l10n.setUpControlServer),
                  ),
                ),
              )
            else if (scrolls)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: grid,
                ),
              )
            else
              Padding(padding: const EdgeInsets.only(right: 8), child: grid),
          ],
        ),
      ),
    );
  }
}

class _CountryTile extends StatelessWidget {
  const _CountryTile({
    required this.system,
    required this.current,
    required this.onTap,
  });

  final CountrySystem system;

  /// Whether the node in use is in this country.
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final best = system.bestLatency;
    return Material(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: current
            ? BorderSide(color: scheme.primary, width: 1.5)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
          child: Column(
            children: [
              CountryHealthBadge(
                code: system.code,
                counts: system.counts,
                size: 56,
              ),
              const SizedBox(height: 10),
              Text(
                placeName(context, system.code),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                context.l10n.galaxyCountryStats(
                  system.planets.length,
                  system.available,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (best != null)
                Text(
                  context.l10n.bestLatency(best),
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
