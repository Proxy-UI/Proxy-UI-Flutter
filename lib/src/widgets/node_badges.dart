import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../models/country_atlas.dart';
import '../models/node_health.dart';
import '../models/upstream_endpoint.dart';
import '../theme/app_theme.dart';
import 'planet_glyph.dart';

/// A country's flag in a circle, or a "location unknown" mark.
class CountryFlagBadge extends StatelessWidget {
  const CountryFlagBadge({super.key, required this.code, this.size = 24});

  /// Two-letter code; empty for an unlocated node.
  final String code;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final normalized = normalizeCountryCode(code);
    final known =
        normalized.isNotEmpty && FlagCode.fromCountryCode(normalized) != null;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outlineVariant, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: known
          ? CountryFlag.fromCountryCode(
              normalized,
              theme: ImageTheme(
                shape: const Circle(),
                width: size,
                height: size,
              ),
            )
          : Icon(
              Icons.travel_explore,
              size: size * 0.62,
              color: scheme.onSurfaceVariant,
            ),
    );
  }
}

/// The localized word for [health].
String healthLabel(BuildContext context, NodeHealth health) => switch (health) {
  NodeHealth.fast => context.l10n.healthFast,
  NodeHealth.fair => context.l10n.healthFair,
  NodeHealth.slow => context.l10n.healthSlow,
  NodeHealth.testing => context.l10n.healthTesting,
  NodeHealth.unreachable => context.l10n.healthUnreachable,
  NodeHealth.untested => context.l10n.healthUntested,
};

/// A test in progress, drawn still.
///
/// A spinner repaints every frame, and any animation makes the engine raster
/// the whole window again — the galaxy included — for as long as the slowest
/// node takes to time out. A run shows the share answered; a single node
/// shows a fixed arc.
class TestingRing extends StatelessWidget {
  const TestingRing({
    super.key,
    required this.size,
    this.progress,
    this.strokeWidth = 2,
    this.color,
  });

  final double size;
  final double? progress;
  final double strokeWidth;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Theme.of(context).colorScheme.primary;
    return SizedBox.square(
      dimension: size,
      child: CircularProgressIndicator(
        value: progress ?? 0.3,
        strokeWidth: strokeWidth,
        color: color,
        backgroundColor: color.withValues(alpha: 0.22),
      ),
    );
  }
}

/// A node's health as a small tonal chip, with its latency when it answered.
class HealthChip extends StatelessWidget {
  const HealthChip({super.key, required this.health, this.latencyMs});

  final NodeHealth health;
  final int? latencyMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = StatusColors.of(context).health(health, theme.colorScheme);
    final label = health.isAvailable && latencyMs != null
        ? '${healthLabel(context, health)} · ${context.l10n.latencyValue(latencyMs!)}'
        : healthLabel(context, health);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 10, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (health == NodeHealth.testing)
            TestingRing(size: 12, strokeWidth: 1.6, color: color)
          else
            PlanetGlyph(color: color, size: 14),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// A protocol's name as a small tag beside an address: QUIC on a node, UDP
/// on a SOCKS5 link. Lists show it only for the exception, never for TCP.
class ProtocolTag extends StatelessWidget {
  const ProtocolTag(this.label, {super.key});

  /// Tags a node whose sessions are carried over QUIC; nothing otherwise.
  static Widget? carrier(UpstreamEndpoint? endpoint) =>
      endpoint?.isQuic == true ? ProtocolTag(endpoint!.transport.label) : null;

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onTertiaryContainer,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// A node's `host:port` on one line, followed by its carrier tag.
class NodeAddressText extends StatelessWidget {
  const NodeAddressText(this.addr, {super.key, this.style});

  /// The catalogue's address, with or without `quic://`.
  final String addr;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final endpoint = UpstreamEndpoint.tryParse(addr);
    final text = Text(
      endpoint?.address ?? addr,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    final tag = ProtocolTag.carrier(endpoint);
    if (tag == null) return text;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: text),
        const SizedBox(width: 6),
        tag,
      ],
    );
  }
}

/// "3m ago", from the coarsest unit that is not zero.
String timeAgo(BuildContext context, DateTime moment) {
  final diff = DateTime.now().difference(moment);
  final strings = context.l10n;
  if (diff.inSeconds < 60) {
    return strings.sAgo(diff.inSeconds.clamp(0, 59).toString());
  }
  if (diff.inMinutes < 60) return strings.mAgo(diff.inMinutes.toString());
  if (diff.inHours < 24) return strings.hAgo(diff.inHours.toString());
  return strings.dAgo(diff.inDays.toString());
}
