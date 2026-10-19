import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import '../models/node_health.dart';
import '../services/windows_typography.dart';

/// The application's Material 3 theme for one seed colour and brightness.
///
/// Every screen draws from this one definition, so cards, chips, inputs and
/// navigation share their shapes and surfaces instead of each page choosing
/// its own.
ThemeData buildAppTheme(Color seed, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: WindowsTypography.themeFamily,
    fontFamilyFallback: WindowsTypography.themeFallback,
  );
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    extensions: [StatusColors.harmonized(scheme)],
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      labelType: NavigationRailLabelType.all,
      groupAlignment: -1,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      elevation: 0,
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.error),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.6),
      space: 1,
      thickness: 1,
    ),
  );
}

/// Status colours Material does not define: healthy, waiting, slow and in
/// progress. Each is harmonised towards the seed colour and taken at the tone
/// Material uses for custom colours, so it reads as part of the palette.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.good,
    required this.fair,
    required this.slow,
    required this.progress,
  });

  factory StatusColors.harmonized(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    final source = scheme.primary.toARGB32();
    Color tone(int design) {
      final hct = Hct.fromInt(Blend.harmonize(design, source));
      final palette = TonalPalette.of(hct.hue, hct.chroma.clamp(40, 80));
      return Color(palette.get(dark ? 78 : 48));
    }

    return StatusColors(
      good: tone(0xFF1E8E3E),
      fair: tone(0xFFF2B500),
      slow: tone(0xFFE8710A),
      progress: tone(0xFF1A73E8),
    );
  }

  final Color good;
  final Color fair;
  final Color slow;
  final Color progress;

  static StatusColors of(BuildContext context) =>
      Theme.of(context).extension<StatusColors>() ??
      StatusColors.harmonized(Theme.of(context).colorScheme);

  /// The colour of a node in [health].
  Color health(NodeHealth health, ColorScheme scheme) => switch (health) {
    NodeHealth.fast => good,
    NodeHealth.fair => fair,
    NodeHealth.slow => slow,
    NodeHealth.testing => progress,
    NodeHealth.unreachable => scheme.error,
    NodeHealth.untested => scheme.outline,
  };

  @override
  StatusColors copyWith({
    Color? good,
    Color? fair,
    Color? slow,
    Color? progress,
  }) => StatusColors(
    good: good ?? this.good,
    fair: fair ?? this.fair,
    slow: slow ?? this.slow,
    progress: progress ?? this.progress,
  );

  @override
  StatusColors lerp(StatusColors? other, double t) {
    if (other == null) return this;
    return StatusColors(
      good: Color.lerp(good, other.good, t)!,
      fair: Color.lerp(fair, other.fair, t)!,
      slow: Color.lerp(slow, other.slow, t)!,
      progress: Color.lerp(progress, other.progress, t)!,
    );
  }
}
