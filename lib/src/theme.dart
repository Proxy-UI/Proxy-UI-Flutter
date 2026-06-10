import 'package:flutter/material.dart';

import 'constants.dart';

/// "Deep Signal" design language.
///
/// A proxy app is quiet infrastructure. Every color seed shares the same
/// canvas — deep blue-black ink in dark, cool paper white in light — and
/// the same amber "in progress" semantics; switching seeds only swaps the
/// accent hue family. The default Aurora seed additionally hand-tunes its
/// accents to the luminous cyan→emerald signature of the connect hero.
/// Cards are flat with hairline borders; glow belongs to the hero alone.
class AppTheme {
  static ThemeData light(ColorSeed seed) =>
      _base(_scheme(seed, Brightness.light));

  static ThemeData dark(ColorSeed seed) =>
      _base(_scheme(seed, Brightness.dark));

  static ColorScheme _scheme(ColorSeed seed, Brightness brightness) {
    var scheme = ColorScheme.fromSeed(
      seedColor: seed.color,
      brightness: brightness,
    );
    if (seed == ColorSeed.aurora) {
      scheme = brightness == Brightness.dark
          ? scheme.copyWith(
              primary: const Color(0xFF22D3EE),
              onPrimary: const Color(0xFF06262E),
              primaryContainer: const Color(0xFF0E3A44),
              onPrimaryContainer: const Color(0xFF9FEAF7),
              secondary: const Color(0xFF34D399),
              onSecondary: const Color(0xFF062B1E),
              secondaryContainer: const Color(0xFF0C3A2B),
              onSecondaryContainer: const Color(0xFFA7F3D0),
            )
          : scheme.copyWith(
              primary: const Color(0xFF0891B2),
              onPrimary: Colors.white,
              primaryContainer: const Color(0xFFCDF1FA),
              onPrimaryContainer: const Color(0xFF064B5C),
              secondary: const Color(0xFF059669),
              onSecondary: Colors.white,
              secondaryContainer: const Color(0xFFCCF3E2),
              onSecondaryContainer: const Color(0xFF065F46),
            );
    }
    return brightness == Brightness.dark ? _ink(scheme) : _paper(scheme);
  }

  /// Shared dark canvas: deep blue-black ink, misty blue-grey text,
  /// amber reserved for in-progress states. Applied to every seed.
  static ColorScheme _ink(ColorScheme scheme) => scheme.copyWith(
    tertiary: const Color(0xFFFCD34D),
    onTertiary: const Color(0xFF3A2A04),
    surface: const Color(0xFF0C1218),
    onSurface: const Color(0xFFE3EBF2),
    surfaceContainerLowest: const Color(0xFF080D12),
    surfaceContainerLow: const Color(0xFF101820),
    surfaceContainer: const Color(0xFF131C25),
    surfaceContainerHigh: const Color(0xFF18222C),
    surfaceContainerHighest: const Color(0xFF1D2934),
    onSurfaceVariant: const Color(0xFF8DA0B0),
    outline: const Color(0xFF3A4A58),
    outlineVariant: const Color(0xFF263340),
  );

  /// Shared light canvas: cool paper white with slate ink text.
  static ColorScheme _paper(ColorScheme scheme) => scheme.copyWith(
    tertiary: const Color(0xFFB45309),
    onTertiary: Colors.white,
    surface: const Color(0xFFF7FAFC),
    onSurface: const Color(0xFF16252F),
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFFFFFFF),
    surfaceContainer: const Color(0xFFEFF4F8),
    surfaceContainerHigh: const Color(0xFFE7EEF3),
    surfaceContainerHighest: const Color(0xFFDFE8EF),
    onSurfaceVariant: const Color(0xFF5A6B78),
    outline: const Color(0xFF93A5B1),
    outlineVariant: const Color(0xFFD7E2EA),
  );

  /// Shared component language: flat app bar, hairline-bordered flat
  /// cards, soft-rounded dialogs. Elevation gives way to layered surface
  /// tones.
  static ThemeData _base(ColorScheme scheme) {
    final theme = ThemeData(useMaterial3: true, colorScheme: scheme);
    return theme.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: theme.appBarTheme.copyWith(
        backgroundColor: scheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: theme.cardTheme.copyWith(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant, width: 0.8),
        ),
      ),
      dialogTheme: theme.dialogTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}
