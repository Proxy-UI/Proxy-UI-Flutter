import 'dart:math' as math;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../models/country_atlas.dart';
import '../models/node_health.dart';
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

/// A country's flag inside the same status ring its star wears in the
/// galaxy: one arc per health, sized by how many nodes are in it.
class CountryHealthBadge extends StatelessWidget {
  const CountryHealthBadge({
    super.key,
    required this.code,
    required this.counts,
    this.size = 56,
  });

  final String code;
  final Map<NodeHealth, int> counts;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = StatusColors.of(context);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _HealthRingPainter(
          segments: [
            for (final health in NodeHealth.displayOrder)
              if ((counts[health] ?? 0) > 0)
                (counts[health]!, status.health(health, scheme)),
          ],
          track: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
        child: Center(
          child: CountryFlagBadge(code: code, size: size * 0.7),
        ),
      ),
    );
  }
}

class _HealthRingPainter extends CustomPainter {
  _HealthRingPainter({required this.segments, required this.track});

  final List<(int, Color)> segments;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.06;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    final total = segments.fold<int>(0, (sum, s) => sum + s.$1);
    if (total == 0) return;
    final gap = segments.length > 1 ? 0.12 : 0.0;
    var start = -math.pi / 2;
    for (final (count, color) in segments) {
      final sweep = math.pi * 2 * count / total;
      canvas.drawArc(
        rect,
        start + gap / 2,
        math.max(0.02, sweep - gap),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_HealthRingPainter old) =>
      old.track != track ||
      old.segments.length != segments.length ||
      [for (var i = 0; i < segments.length; i++) old.segments[i] != segments[i]]
          .any((changed) => changed);
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
            SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
            )
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
