import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../../models/country_atlas.dart';
import '../../models/node_health.dart';
import '../../providers/proxy_provider.dart';
import '../../services/build_capabilities.dart';
import '../../theme/app_theme.dart';
import '../../widgets/node_badges.dart';
import '../../widgets/planet_glyph.dart';
import 'galaxy/galaxy_model.dart';
import 'node_actions.dart';
import 'node_socks5_link.dart';

/// What is known about the selected body: this device, a country, or a node,
/// with the actions that apply to it.
class NodeDetailsPanel extends StatelessWidget {
  const NodeDetailsPanel({
    super.key,
    required this.scene,
    required this.selected,
    required this.actions,
    required this.onSelect,
    required this.onClose,
    this.scrollController,
  });

  /// The whole catalogue's scene, so a node hidden by a filter still has
  /// its details.
  final GalaxyScene scene;
  final String selected;
  final NodeActions actions;
  final ValueChanged<String> onSelect;
  final VoidCallback onClose;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (selected == homeId) {
      body = _HomeDetails(scene: scene, onSelect: onSelect, onClose: onClose);
    } else if (scene.systemOf(selected) case final system?) {
      body = _CountryDetails(
        system: system,
        actions: actions,
        onSelect: onSelect,
        onClose: onClose,
      );
    } else if (scene.planetOf(selected) case final found?) {
      body = _NodeDetails(
        system: found.system,
        planet: found.planet,
        actions: actions,
        onSelect: onSelect,
        onClose: onClose,
      );
    } else {
      body = const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: actions,
      builder: (context, _) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 20),
        child: body,
      ),
    );
  }
}

String placeName(BuildContext context, String code) => code.isEmpty
    ? context.l10n.galaxyUnlocated
    : countryName(code, Localizations.localeOf(context).languageCode);

class _Header extends StatelessWidget {
  const _Header({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onClose,
    this.selectableTitle = false,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onClose;
  final bool selectableTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 4), child: leading),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              selectableTitle
                  ? SelectableText(title, style: titleStyle, maxLines: 1)
                  : Text(
                      title,
                      style: titleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: context.l10n.close,
          onPressed: onClose,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}

/// The device in the user's hand, and what it is connected through.
class _HomeDetails extends StatelessWidget {
  const _HomeDetails({
    required this.scene,
    required this.onSelect,
    required this.onClose,
  });

  final GalaxyScene scene;
  final ValueChanged<String> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProxyState>();
    final scheme = Theme.of(context).colorScheme;
    final current = scene.current;
    final capture = state.isTunRunning
        ? (Platform.isAndroid || BuildCapabilities.usesPacketTunnel
              ? 'VPN'
              : 'TUN')
        : 'SOCKS5';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          leading: PlanetGlyph(color: scheme.primary, size: 36),
          title: context.l10n.galaxyHome,
          subtitle: state.isRunning
              ? '${context.l10n.connected} · $capture'
              : context.l10n.disconnected,
          onClose: onClose,
        ),
        const SizedBox(height: 16),
        Text(
          context.l10n.homeDetail,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        _InfoRow(
          label: context.l10n.localPort,
          value: '127.0.0.1:${state.config.localPort}',
        ),
        if (state.config.serverHost.isNotEmpty)
          _InfoRow(
            label: context.l10n.server,
            value: '${state.config.serverHost}:${state.config.serverPort}',
          ),
        const SizedBox(height: 12),
        if (current != null)
          _NodeRow(
            planet: current.planet,
            onTap: () => onSelect(current.planet.id),
          )
        else
          Text(
            context.l10n.notConnectedHint,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

/// One country: how its nodes are doing, and each of them.
class _CountryDetails extends StatelessWidget {
  const _CountryDetails({
    required this.system,
    required this.actions,
    required this.onSelect,
    required this.onClose,
  });

  final CountrySystem system;
  final NodeActions actions;
  final ValueChanged<String> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final total = system.planets.length;
    final best = system.bestLatency;
    final planets = [...system.planets]
      ..sort((a, b) {
        final byHealth = NodeHealth.displayOrder
            .indexOf(a.node.health)
            .compareTo(NodeHealth.displayOrder.indexOf(b.node.health));
        if (byHealth != 0) return byHealth;
        return (a.node.latencyMs ?? 1 << 30).compareTo(
          b.node.latencyMs ?? 1 << 30,
        );
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          leading: CountryFlagBadge(code: system.code, size: 36),
          title: placeName(context, system.code),
          subtitle: [
            if (!system.unknown) system.code,
            context.l10n.regionAvailable(system.available, total),
            if (best != null) context.l10n.bestLatency(best),
          ].join(' · '),
          onClose: onClose,
        ),
        const SizedBox(height: 16),
        _HealthBar(counts: system.counts, total: total),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          onPressed: actions.testingMany
              ? null
              : () => actions.testMany(context, [
                  for (final planet in system.planets) planet.node.node,
                ]),
          icon: actions.testingMany
              ? TestingRing(size: 18, progress: actions.testProgress)
              : const Icon(Icons.network_check),
          label: Text(context.l10n.testRegion),
        ),
        const SizedBox(height: 12),
        for (final planet in planets)
          _NodeRow(planet: planet, onTap: () => onSelect(planet.id)),
      ],
    );
  }
}

/// A stacked bar of a country's nodes by health, with the counts beneath.
class _HealthBar extends StatelessWidget {
  const _HealthBar({required this.counts, required this.total});

  final Map<NodeHealth, int> counts;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = StatusColors.of(context);
    final present = [
      for (final health in NodeHealth.displayOrder)
        if ((counts[health] ?? 0) > 0) health,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                for (final health in present)
                  Expanded(
                    flex: counts[health]!,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      color: status.health(health, theme.colorScheme),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (final health in present)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PlanetGlyph(
                    color: status.health(health, theme.colorScheme),
                    size: 14,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${healthLabel(context, health)} ${counts[health]}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// A node as one row: its health, address and latency.
class _NodeRow extends StatelessWidget {
  const _NodeRow({required this.planet, required this.onTap});

  final NodePlanet planet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = planet.node;
    final color = StatusColors.of(context)
        .health(node.health, theme.colorScheme);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        child: Row(
          children: [
            PlanetGlyph(color: color, size: 22, ring: node.current),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                node.node.addr,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: node.current ? FontWeight.w600 : null,
                ),
              ),
            ),
            if (node.current) ...[
              Icon(Icons.link, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
            ],
            Text(
              node.health.isAvailable && node.latencyMs != null
                  ? context.l10n.latencyValue(node.latencyMs!)
                  : healthLabel(context, node.health),
              style: theme.textTheme.labelMedium?.copyWith(
                color: node.health.isAvailable
                    ? theme.colorScheme.onSurface
                    : color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// One node: where it is, how it answered, and what can be done with it.
class _NodeDetails extends StatelessWidget {
  const _NodeDetails({
    required this.system,
    required this.planet,
    required this.actions,
    required this.onSelect,
    required this.onClose,
  });

  final CountrySystem system;
  final NodePlanet planet;
  final NodeActions actions;
  final ValueChanged<String> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProxyState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final node = planet.node;
    final info = node.node;
    final verification = state.verificationFor(info);
    final color = StatusColors.of(context).health(node.health, scheme);
    final switching = actions.isSwitching(info);
    final testing = state.isVerifyingNode(info);
    int? port;
    try {
      port = info.port;
    } on FormatException {
      port = null;
    }
    final drift =
        verification != null && verification.disagreesWith(info.country);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          leading: PlanetGlyph(color: color, size: 36, ring: node.current),
          title: node.host,
          selectableTitle: true,
          subtitle: [
            if (port != null) '${context.l10n.port3} $port',
            placeName(context, system.code),
          ].join(' · '),
          onClose: onClose,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ActionChip(
              avatar: CountryFlagBadge(code: system.code, size: 18),
              label: Text(placeName(context, system.code)),
              onPressed: () => onSelect(system.id),
            ),
            HealthChip(health: node.health, latencyMs: node.latencyMs),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: node.current && state.isRunning
                  ? FilledButton.tonalIcon(
                      onPressed: null,
                      icon: const Icon(Icons.check),
                      label: Text(context.l10n.nodeInUse),
                    )
                  : FilledButton.icon(
                      key: const Key('node-connect'),
                      onPressed: actions.canConnect(info)
                          ? () => actions.connect(context, info)
                          : null,
                      icon: switching
                          ? SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: scheme.onPrimary,
                              ),
                            )
                          : const Icon(Icons.power_settings_new),
                      label: Text(context.l10n.nodeConnect),
                    ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: testing ? null : () => actions.test(context, info),
              icon: testing
                  ? const TestingRing(size: 18)
                  : const Icon(Icons.speed),
              label: Text(context.l10n.testLabel),
            ),
            // Both put the node on the clipboard, in two shapes.
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.copy),
                  onPressed: () => actions.copyAddress(context, info),
                  child: Text(context.l10n.copyAddress),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.ios_share),
                  onPressed: () => actions.export(context, info),
                  child: Text(context.l10n.exportToClipboard),
                ),
              ],
              builder: (context, controller, _) => IconButton(
                tooltip: context.l10n.copy,
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.more_vert),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _InfoRow(label: context.l10n.nodeAddress, value: info.addr),
        if (verification?.egressIp.isNotEmpty ?? false)
          _InfoRow(
            label: context.l10n.nodeEgressIp,
            value: verification!.egressIp,
          ),
        _InfoRow(
          label: context.l10n.latency,
          value: node.latencyMs == null
              ? context.l10n.nA
              : context.l10n.latencyValue(node.latencyMs!),
        ),
        _InfoRow(
          label: context.l10n.nodeChecked,
          value: verification == null
              ? context.l10n.nodeNeverTested
              : timeAgo(context, verification.checkedAt),
        ),
        _InfoRow(
          label: context.l10n.nodeLastSeen,
          value: info.lastSeen.millisecondsSinceEpoch == 0
              ? context.l10n.nA
              : timeAgo(context, info.lastSeen),
        ),
        if (info.nodeId.isNotEmpty && info.nodeId != info.addr)
          _InfoRow(label: context.l10n.nodeId, value: info.nodeId),
        if (info.country.isNotEmpty || info.region.isNotEmpty)
          _InfoRow(
            label: context.l10n.nodeCatalogueRegion,
            value: [
              info.country,
              info.region,
            ].where((part) => part.isNotEmpty).join(' · '),
          ),
        NodeSocks5Link(node: info),
        if (drift) ...[
          const SizedBox(height: 12),
          _Notice(
            icon: Icons.compare_arrows,
            color: scheme.tertiaryContainer,
            onColor: scheme.onTertiaryContainer,
            text: context.l10n.egressDiffers(
              verification.countryCode,
              info.country,
            ),
          ),
        ],
        if (verification != null &&
            !verification.isVerified &&
            (verification.error?.isNotEmpty ?? false)) ...[
          const SizedBox(height: 12),
          _Notice(
            icon: Icons.cloud_off,
            color: scheme.errorContainer,
            onColor: scheme.onErrorContainer,
            text: verification.error!.trim(),
          ),
        ],
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              maxLines: 1,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.onColor,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final Color onColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: onColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: onColor),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: context.l10n.copy,
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            icon: Icon(Icons.copy, size: 14, color: onColor),
          ),
        ],
      ),
    );
  }
}
