/// Country flags as square raster images, for painting a flag as the face of
/// a country's star.
///
/// The flags are the vector assets `country_flags` already ships, so the
/// galaxy shows exactly the flag the rest of the app shows for that country.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/services.dart';
import 'package:jovial_svg/jovial_svg.dart';

/// Rasterised flags, loaded on first use and kept for the process.
class FlagAtlas {
  FlagAtlas._();

  static final FlagAtlas instance = FlagAtlas._();

  /// Edge of each image in pixels: crisp up to a star of about 64 points on
  /// a 2x display.
  static const int resolution = 128;

  final Map<String, ui.Image> _images = {};
  final Set<String> _pending = {};
  final Set<String> _missing = {};
  final List<void Function()> _listeners = [];

  /// Called whenever a flag finishes loading.
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// The flag for [countryCode], or null until it has loaded (or when there
  /// is none). Asking starts the load.
  ui.Image? imageFor(String countryCode) {
    final code = countryCode.toUpperCase();
    final image = _images[code];
    if (image != null || _missing.contains(code)) return image;
    if (_pending.add(code)) _load(code);
    return null;
  }

  Future<void> _load(String code) async {
    final flagCode = FlagCode.fromCountryCode(code);
    if (flagCode == null) {
      _missing.add(code);
      _pending.remove(code);
      return;
    }
    try {
      final si = await ScalableImage.fromSIAsset(
        rootBundle,
        'packages/country_flags/res/si/$flagCode.si',
      );
      final viewport = si.viewport;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      // Cover the square: the flag's centre stays in view, its long side is
      // cropped, as on a round badge.
      final scale = math.max(
        resolution / viewport.width,
        resolution / viewport.height,
      );
      canvas
        ..translate(
          (resolution - viewport.width * scale) / 2,
          (resolution - viewport.height * scale) / 2,
        )
        ..scale(scale)
        ..translate(-viewport.left, -viewport.top);
      si.paint(canvas);
      final picture = recorder.endRecording();
      try {
        _images[code] = await picture.toImage(resolution, resolution);
      } finally {
        picture.dispose();
      }
      for (final listener in List.of(_listeners)) {
        listener();
      }
    } catch (_) {
      // No flag, or no rasteriser (tests): the star keeps its plain face.
      _missing.add(code);
    } finally {
      _pending.remove(code);
    }
  }
}
