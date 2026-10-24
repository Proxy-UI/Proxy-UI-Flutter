import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../models/node_health.dart';
import '../models/upstream_endpoint.dart';
import '../providers/proxy_provider.dart';
import '../services/build_capabilities.dart';
import '../theme/app_theme.dart';
import '../widgets/lan_proxy_link.dart';
import '../widgets/node_badges.dart';
import 'nodes/control_server_dialog.dart';
import 'nodes/galaxy/galaxy_canvas.dart';
import 'nodes/galaxy/galaxy_model.dart';
import 'nodes/node_actions.dart';
import 'nodes/node_details_panel.dart';
import 'nodes/nodes_page.dart';
import 'proxy_controls.dart';

/// The connection at a glance.
///
/// On a desktop window the node galaxy fills the page and the controls float
/// over its left edge in one compact panel: the power control, the node in
/// use, traffic capture and the local proxy. On a phone, or any window too
/// small for the galaxy to read, the panel fills one screen and the galaxy is
/// a button away. Clicking a country or a node opens it on the node map.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.onOpenNodes});

  /// Open the node map, selecting [selection] when given.
  final void Function(String? selection) onOpenNodes;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProxyState>();
    askQuicSupportAfterFrame(state);
    final nodes = galaxyNodesOf(state);
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 900 && box.maxHeight >= 520) {
          return _GalaxyDashboard(
            state: state,
            nodes: nodes,
            onOpenNodes: onOpenNodes,
          );
        }
        final panel = _ControlPanel(
          state: state,
          nodes: nodes,
          onOpenNodes: onOpenNodes,
          floating: false,
        );
        final map = _NodeMapButton(
          nodes: nodes,
          onOpen: () => onOpenNodes(null),
        );
        final width = box.maxWidth < 560 ? box.maxWidth : 560.0;
        // Everything fits one screen; only a very short window scrolls.
        if (box.maxHeight >= 520) {
          return Center(
            child: SizedBox(
              width: width,
              height: box.maxHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: panel),
                    const SizedBox(height: 12),
                    map,
                  ],
                ),
              ),
            ),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Center(
            child: SizedBox(
              width: width - 32,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: 480, child: panel),
                  const SizedBox(height: 12),
                  map,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The galaxy filling the page, with the control panel over its left edge.
class _GalaxyDashboard extends StatefulWidget {
  const _GalaxyDashboard({
    required this.state,
    required this.nodes,
    required this.onOpenNodes,
  });

  final ProxyState state;
  final List<GalaxyNode> nodes;
  final void Function(String? selection) onOpenNodes;

  @override
  State<_GalaxyDashboard> createState() => _GalaxyDashboardState();
}

class _GalaxyDashboardState extends State<_GalaxyDashboard> {
  static const double _panelWidth = 360;
  List<GalaxyNode>? _nodes;
  GalaxyScene _scene = GalaxyScene.empty;

  void _syncScene() {
    final previous = _nodes;
    final next = widget.nodes;
    if (previous != null &&
        previous.length == next.length &&
        _scene.connected == widget.state.isRunning &&
        Iterable<int>.generate(next.length).every((i) {
          final a = previous[i], b = next[i];
          return a.id == b.id &&
              a.country == b.country &&
              a.health == b.health &&
              a.current == b.current &&
              a.latencyMs == b.latencyMs &&
              a.quic == b.quic &&
              a.carrier == b.carrier &&
              identical(a.node, b.node);
        })) {
      return;
    }
    _nodes = next;
    _scene = buildGalaxyScene(next, connected: widget.state.isRunning);
  }

  @override
  Widget build(BuildContext context) {
    _syncScene();
    final state = widget.state;
    final scene = _scene;
    final onOpenNodes = widget.onOpenNodes;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Card(
        key: const Key('galaxy-dashboard'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: Stack(
          children: [
            Positioned.fill(
              child: GalaxyCanvas(
                scene: scene,
                text: galaxyTextFor(context),
                selected: null,
                onSelect: (id) {
                  if (id != null) onOpenNodes(id);
                },
                semanticLabel: context.l10n.galaxySemantics,
                // Framed in the part the panel leaves uncovered.
                inset: const EdgeInsets.only(left: _panelWidth + 24, top: 40),
              ),
            ),
            Positioned(
              top: 14,
              left: _panelWidth + 40,
              right: 14,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      scene.isEmpty ? '' : _summary(context, widget.nodes),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('open-node-map'),
                    tooltip: context.l10n.openNodeMap,
                    onPressed: () => onOpenNodes(null),
                    icon: const Icon(Icons.open_in_full),
                  ),
                ],
              ),
            ),
            if (state.nodes.isEmpty)
              Positioned.fill(
                left: _panelWidth + 24,
                // Below the home star, which sits at the centre.
                child: Align(
                  alignment: const Alignment(0, 0.4),
                  child: FilledButton.icon(
                    onPressed: () => ControlServerDialog.show(context),
                    icon: const Icon(Icons.hub_outlined),
                    label: Text(context.l10n.setUpControlServer),
                  ),
                ),
              ),
            Positioned(
              left: 14,
              top: 14,
              bottom: 14,
              width: _panelWidth,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  child: _ControlPanel(
                    state: state,
                    nodes: widget.nodes,
                    onOpenNodes: onOpenNodes,
                    floating: true,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _summary(BuildContext context, List<GalaxyNode> nodes) {
  final regions = nodes
      .map((node) => node.country)
      .where((code) => code.isNotEmpty)
      .toSet()
      .length;
  final available = nodes.where((node) => node.health.isAvailable).length;
  return context.l10n.nodeMapSummary(regions, available, nodes.length);
}

/// Everything the user controls: one panel floating over the galaxy with
/// the power control beside its status, or, on a phone, the power control
/// centred on the page above a card of rows. The power area there is open
/// page rather than a tall empty box.
class _ControlPanel extends StatelessWidget {
  const _ControlPanel({
    required this.state,
    required this.nodes,
    required this.onOpenNodes,
    required this.floating,
  });

  final ProxyState state;
  final List<GalaxyNode> nodes;
  final void Function(String? selection) onOpenNodes;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = [
      _CurrentNodeRow(state: state, nodes: nodes, onOpenNodes: onOpenNodes),
      const Divider(height: 1, indent: 20, endIndent: 20),
      _CaptureRow(state: state),
      const Divider(height: 1, indent: 20, endIndent: 20),
      _LocalProxyRow(state: state),
    ];
    if (floating) {
      return Material(
        key: const Key('control-panel'),
        color: scheme.surfaceContainerLow,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        surfaceTintColor: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PowerSection(state: state, horizontal: true),
            ...rows,
            const SizedBox(height: 6),
          ],
        ),
      );
    }
    return Column(
      key: const Key('control-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: _PowerSection(state: state, horizontal: false),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ),
      ],
    );
  }
}

/// The power control and what the connection is.
class _PowerSection extends StatelessWidget {
  const _PowerSection({required this.state, required this.horizontal});

  final ProxyState state;

  /// Side by side, for the floating panel; stacked and centred otherwise.
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = state.isRunning;
    final busy = state.isProxyOperationInProgress || state.isTunBusy;
    final endpoint = state.config.serverHost.isEmpty
        ? context.l10n.configureAServerToGetStarted
        : endpointLabel(state.config.serverHost, state.config.serverPort);
    final align = horizontal
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.center;
    final status = Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
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
        const SizedBox(height: 2),
        Text(
          endpoint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          connectionModeLabel(context, state),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    if (horizontal) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Row(
          children: [
            _PowerButton(state: state, size: 96),
            const SizedBox(width: 14),
            Expanded(child: status),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PowerButton(state: state, size: 128),
          const SizedBox(height: 12),
          status,
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
  bool _wasRunning = false;
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

  /// A connection gets one pulse; only an in-flight operation keeps moving.
  void _sync() {
    final running = widget.state.isRunning;
    final newlyConnected = running && !_wasRunning;
    _wasRunning = running;
    final animate =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (!animate || !running && !widget.state.isProxyOperationInProgress) {
      _halo
        ..stop()
        ..value = 0;
    } else if (widget.state.isProxyOperationInProgress) {
      if (!_halo.isAnimating) _halo.repeat();
    } else if (newlyConnected || _halo.isAnimating) {
      _halo.forward(from: 0);
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
    // Before any server is configured, the one obvious control on the page
    // leads to the configuration instead of sitting there disabled.
    final unconfigured = state.config.serverHost.isEmpty && !running;
    final label = unconfigured
        ? context.l10n.configureAServerToGetStarted
        : running
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
                        : unconfigured
                        ? scheme.secondaryContainer
                        : scheme.surfaceContainerHighest,
                    foregroundColor: running
                        ? scheme.onPrimary
                        : unconfigured
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  onPressed: unconfigured
                      ? () => showConfigDialog(context)
                      : canToggleProxy(state)
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
                      : Icon(
                          unconfigured ? Icons.tune : Icons.power_settings_new,
                          size: size * 0.32,
                        ),
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

/// The node traffic goes through, with how it last answered over the
/// carrier in use; opens it on the node map.
class _CurrentNodeRow extends StatelessWidget {
  const _CurrentNodeRow({
    required this.state,
    required this.nodes,
    required this.onOpenNodes,
  });

  final ProxyState state;
  final List<GalaxyNode> nodes;
  final void Function(String? selection) onOpenNodes;

  @override
  Widget build(BuildContext context) {
    final current = nodes.where((node) => node.current).firstOrNull;
    // The map may be showing the other carrier; this row is the connection.
    final carrier = state.currentCarrier ?? UpstreamTransport.tcp;
    return _PanelRow(
      key: const Key('current-node'),
      onTap: () => onOpenNodes(current?.id),
      leading: CountryFlagBadge(code: current?.country ?? '', size: 30),
      title: current == null
          ? context.l10n.currentNodeTitle
          : placeName(context, current.country),
      // The status above and the chip beside already name the carrier.
      detail: current == null
          ? context.l10n.noCurrentNode
          : UpstreamEndpoint.tryFromHost(
                  state.config.serverHost,
                  state.config.serverPort,
                )?.address ??
                current.address,
      trailing: [
        if (current != null)
          HealthChip(
            health: state.healthOf(current.node, carrier),
            latencyMs: state.latencyOf(current.node, carrier),
            overQuic: carrier == UpstreamTransport.quic,
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
        if (Platform.isMacOS && !BuildCapabilities.usesPacketTunnel)
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
        else if (!BuildCapabilities.usesPacketTunnel)
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

/// The way to the galaxy where there is no room to show it: a button that
/// already says how the catalogue is doing.
class _NodeMapButton extends StatelessWidget {
  const _NodeMapButton({required this.nodes, required this.onOpen});

  final List<GalaxyNode> nodes;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = StatusColors.of(context);
    final counts = <NodeHealth, int>{};
    for (final node in nodes) {
      counts.update(node.health, (n) => n + 1, ifAbsent: () => 1);
    }
    return Material(
      key: const Key('open-node-map'),
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.blur_circular,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      context.l10n.nodeMapTitle,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      nodes.isEmpty
                          ? context.l10n.noNodesHint
                          : _summary(context, nodes),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (nodes.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: SizedBox(
                          height: 5,
                          child: Row(
                            children: [
                              for (final health in NodeHealth.displayOrder)
                                if ((counts[health] ?? 0) > 0)
                                  Expanded(
                                    flex: counts[health]!,
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 1,
                                      ),
                                      color: status.health(health, scheme),
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
