import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../widgets/planet_glyph.dart';

/// Reuses health, home and flag spheres, including their lighting and shadows.
/// Each canvas owns its images; asynchronous renders cannot outlive visibility.
class PlanetAtlas {
  static const double radius = 32;
  static const int edge = 256;
  final Map<Object, ui.Image> _images = {};
  final Set<Object> _pending = {};
  final Set<Object> _failed = {};
  ColorScheme? _scheme;
  bool _enabled = false;
  int _generation = 0;

  static int _liveBytes = 0;

  /// Bytes held by every canvas's planet images: for diagnostics (the galaxy
  /// resource probe).
  static int get liveBytes => _liveBytes;

  set enabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) dispose();
  }

  void palette(ColorScheme scheme) {
    if (_scheme == scheme) return;
    dispose();
    _scheme = scheme;
  }

  ui.Image? imageFor(
    Color color,
    bool dark,
    VoidCallback ready, {
    double glow = 0.9,
  }) {
    if (!_enabled) return null;
    final key = (color, dark, glow);
    final image = _images[key];
    if (image == null && !_failed.contains(key) && _pending.add(key)) {
      _render(
        key,
        ready,
        (canvas) => paintPlanet(
          canvas,
          const Offset(edge / 2, edge / 2),
          radius,
          color,
          dark: dark,
          glow: glow,
        ),
      );
    }
    return image;
  }

  ui.Image? flagFor(String code, ui.Image flag, bool dark, VoidCallback ready) {
    if (!_enabled) return null;
    final key = (code, dark);
    final image = _images[key];
    if (image == null && !_failed.contains(key) && _pending.add(key)) {
      _render(
        key,
        ready,
        (canvas) => paintFlagSphere(
          canvas,
          flag,
          const Offset(edge / 2, edge / 2),
          radius,
          dark,
        ),
      );
    }
    return image;
  }

  ui.Image? glowFor(Color color, VoidCallback ready) {
    if (!_enabled) return null;
    final opaque = color.withValues(alpha: 1);
    final key = ('glow', opaque);
    final image = _images[key];
    if (image == null && !_failed.contains(key) && _pending.add(key)) {
      _render(key, ready, (canvas) {
        final rect = Rect.fromCircle(
          center: Offset(edge / 2, edge / 2),
          radius: radius * 2.5,
        );
        canvas.drawOval(
          rect,
          Paint()
            ..shader = RadialGradient(
              colors: [
                opaque.withValues(alpha: 0.87),
                opaque.withValues(alpha: 0.65),
                opaque.withValues(alpha: 0.20),
                opaque.withValues(alpha: 0),
              ],
              stops: const [0, 0.3, 0.55, 1],
            ).createShader(rect),
        );
      });
    }
    return image;
  }

  Future<void> _render(
    Object key,
    VoidCallback ready,
    void Function(Canvas) paint,
  ) async {
    final generation = _generation;
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder));
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(edge, edge);
      if (generation != _generation) {
        image.dispose();
        return;
      }
      _images[key] = image;
      _liveBytes += image.width * image.height * 4;
      ready();
    } catch (_) {
      // The vector sphere remains available where offscreen rendering fails.
      if (generation == _generation) _failed.add(key);
    } finally {
      picture.dispose();
      if (generation == _generation) _pending.remove(key);
    }
  }

  void dispose() {
    _generation++;
    for (final image in _images.values) {
      _liveBytes -= image.width * image.height * 4;
      image.dispose();
    }
    _images.clear();
    _pending.clear();
    _failed.clear();
  }
}

void paintFlagSphere(
  Canvas canvas,
  ui.Image flag,
  Offset c,
  double radius,
  bool dark,
) {
  const opacity = 1.0;
  final rect = Rect.fromCircle(center: c, radius: radius);
  if (!dark) {
    canvas.drawOval(
      Rect.fromCenter(
        center: c + Offset(radius * 0.15, radius * 0.95),
        width: radius * 1.9,
        height: radius * 0.55,
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.12 * opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.35),
    );
  }
  canvas.save();
  canvas.clipPath(Path()..addOval(rect));
  canvas.drawImageRect(
    flag,
    Rect.fromLTWH(0, 0, flag.width.toDouble(), flag.height.toDouble()),
    rect,
    Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Colors.white.withValues(alpha: opacity),
  );
  // Shade the flag into a sphere: lit upper left, dark lower right.
  canvas.drawRect(
    rect,
    Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.4, -0.45),
        radius: 1.1,
        colors: [
          Colors.white.withValues(alpha: 0.18 * opacity),
          Colors.transparent,
          Colors.black.withValues(alpha: (dark ? 0.5 : 0.32) * opacity),
        ],
        stops: const [0, 0.5, 1],
      ).createShader(rect),
  );
  canvas.restore();
  paintSphereLight(canvas, c, radius, dark: dark, opacity: opacity);
}
