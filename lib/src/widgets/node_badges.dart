import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../models/country_atlas.dart';
import '../models/node_health.dart';
import '../models/quic_support.dart';
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

/// [latencyMs] as text, naming QUIC when it carried the measurement:
/// "120 ms" or "QUIC 120 ms".
String latencyText(
  BuildContext context,
  int latencyMs, {
  bool overQuic = false,
}) {
  final value = context.l10n.latencyValue(latencyMs);
  return overQuic ? '${UpstreamTransport.quic.label} $value' : value;
}

/// [health] in words, naming QUIC when a QUIC test is what failed, so that
/// "unreachable" is not read as unreachable over TCP too.
String quicFailureText(
  BuildContext context,
  NodeHealth health, {
  bool overQuic = false,
}) => overQuic && health == NodeHealth.unreachable
    ? '${healthLabel(context, health)} · ${UpstreamTransport.quic.label}'
    : healthLabel(context, health);

/// A node's health as a small tonal chip, with its latency when it answered.
class HealthChip extends StatelessWidget {
  const HealthChip({
    super.key,
    required this.health,
    this.latencyMs,
    this.overQuic = false,
  });

  final NodeHealth health;
  final int? latencyMs;

  /// Whether [latencyMs] was measured over QUIC.
  final bool overQuic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = StatusColors.of(context).health(health, theme.colorScheme);
    final label = health.isAvailable && latencyMs != null
        ? '${healthLabel(context, health)} · '
              '${latencyText(context, latencyMs!, overQuic: overQuic)}'
        : quicFailureText(context, health, overQuic: overQuic);
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
  const ProtocolTag(this.label, {super.key, this.tooltip, this.muted = false});

  final String label;
  final String? tooltip;

  /// Outlined rather than filled, for an absence such as "No QUIC".
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: muted ? null : scheme.tertiaryContainer,
        border: muted ? Border.all(color: scheme.outlineVariant) : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: muted ? scheme.onSurfaceVariant : scheme.onTertiaryContainer,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
    return tooltip == null ? tag : Tooltip(message: tooltip, child: tag);
  }
}

/// A node's `host:port` on one line, followed by a QUIC tag when it serves
/// QUIC: addressed over it, or reporting a QUIC port beside its TCP one.
class NodeAddressText extends StatelessWidget {
  const NodeAddressText(
    this.addr, {
    super.key,
    this.style,
    this.quic = QuicSupport.unknown,
    this.withoutQuic = false,
  });

  /// The catalogue's address, with or without `quic://`.
  final String addr;
  final TextStyle? style;

  /// What the node said about QUIC; nothing is shown while unknown.
  final QuicSupport quic;

  /// Marks a node a QUIC test just left out for having no QUIC endpoint.
  final bool withoutQuic;

  @override
  Widget build(BuildContext context) {
    final endpoint = UpstreamEndpoint.tryParse(addr);
    final text = Text(
      endpoint?.address ?? addr,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    final quicPort = endpoint?.isQuic == true ? null : quic.port;
    final tag = endpoint?.isQuic == true || quicPort != null
        ? ProtocolTag(
            UpstreamTransport.quic.label,
            tooltip: quicPort == null
                ? null
                : context.l10n.quicOnUdpPort(quicPort.toString()),
          )
        : withoutQuic
        ? ProtocolTag(context.l10n.noQuic, muted: true)
        : null;
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
