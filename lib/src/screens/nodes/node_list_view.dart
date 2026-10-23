import 'package:flutter/material.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../../theme/app_theme.dart';
import '../../widgets/node_badges.dart';
import '../../widgets/planet_glyph.dart';
import '../proxy_controls.dart';
import 'galaxy/galaxy_model.dart';
import 'node_actions.dart';
import 'node_details_panel.dart';

/// The catalogue as a list, one section per country, for when a list is
/// quicker than the map: scanning addresses, or using a screen reader.
class NodeListView extends StatelessWidget {
  const NodeListView({
    super.key,
    required this.scene,
    required this.order,
    required this.sortByLatency,
    required this.selected,
    required this.actions,
    required this.onSelect,
    this.padding = EdgeInsets.zero,
  });

  /// The filtered scene.
  final GalaxyScene scene;

  /// Each node's place in the server's own order.
  final Map<String, int> order;
  final bool sortByLatency;
  final String? selected;
  final NodeActions actions;
  final ValueChanged<String> onSelect;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    final systems = [...scene.systems]
      ..sort((a, b) {
        if (a.unknown != b.unknown) return a.unknown ? 1 : -1;
        final byCount = b.planets.length.compareTo(a.planets.length);
        if (byCount != 0) return byCount;
        return placeName(context, a.code).compareTo(placeName(context, b.code));
      });
    final items = <Object>[];
    for (final system in systems) {
      items.add(system);
      final planets = [...system.planets]
        ..sort((a, b) {
          if (sortByLatency) {
            final left = a.node.health.isAvailable ? a.node.latencyMs : null;
            final right = b.node.health.isAvailable ? b.node.latencyMs : null;
            if (left != null || right != null) {
              if (left == null) return 1;
              if (right == null) return -1;
              final byLatency = left.compareTo(right);
              if (byLatency != 0) return byLatency;
            }
          }
          return (order[a.id] ?? 0).compareTo(order[b.id] ?? 0);
        });
      items.addAll(planets);
    }
    return ListenableBuilder(
      listenable: actions,
      builder: (context, _) => ListView.builder(
        key: ValueKey('node-list-$language'),
        padding: padding,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          if (item is CountrySystem) {
            return _SectionHeader(
              system: item,
              first: index == 0,
              onTap: () => onSelect(item.id),
            );
          }
          final planet = item as NodePlanet;
          return _NodeTile(
            planet: planet,
            selected: planet.id == selected,
            actions: actions,
            onTap: () => onSelect(planet.id),
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.system,
    required this.first,
    required this.onTap,
  });

  final CountrySystem system;
  final bool first;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final best = system.bestLatency;
    return Padding(
      padding: EdgeInsets.only(top: first ? 4 : 20, bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              CountryFlagBadge(code: system.code, size: 26),
              const SizedBox(width: 12),
              Text(
                placeName(context, system.code),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  [
                    context.l10n.regionAvailable(
                      system.available,
                      system.planets.length,
                    ),
                    if (best != null) context.l10n.bestLatency(best),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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

class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.planet,
    required this.selected,
    required this.actions,
    required this.onTap,
  });

  final NodePlanet planet;
  final bool selected;
  final NodeActions actions;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final node = planet.node;
    final info = node.node;
    final color = StatusColors.of(context).health(node.health, scheme);
    final verification = actions.state.verificationFor(info);
    final details = [
      if (verification?.egressIp.isNotEmpty ?? false)
        '${context.l10n.nodeEgressIp} ${verification!.egressIp}',
      if (verification != null)
        '${context.l10n.nodeChecked} ${timeAgo(context, verification.checkedAt)}'
      else
        context.l10n.healthUntested,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: selected
          ? scheme.secondaryContainer
          : node.current
          ? scheme.primaryContainer.withValues(alpha: 0.45)
          : scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              PlanetGlyph(color: color, size: 26, ring: node.current),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NodeAddressText(
                      info.addr,
                      quic: actions.state.quicSupportOf(info),
                      withoutQuic: actions.skippedWithoutQuic(info),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              HealthChip(
                health: node.health,
                latencyMs: node.latencyMs,
                overQuic: node.testedOverQuic,
              ),
              const SizedBox(width: 6),
              if (node.current && actions.state.isRunning)
                Tooltip(
                  message: context.l10n.nodeInUse,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.link, color: scheme.primary),
                  ),
                )
              else
                IconButton(
                  tooltip: actions.restartsTun(info)
                      ? context.l10n.connectRestartsTun(captureName)
                      : context.l10n.nodeConnect,
                  onPressed: actions.canConnect(info)
                      ? () => actions.connect(context, info)
                      : null,
                  icon: actions.isSwitching(info)
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      // Under TUN nearly every other node is another host, so
                      // the icon stays put; the tooltip and the panel say it.
                      : const Icon(Icons.power_settings_new),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
