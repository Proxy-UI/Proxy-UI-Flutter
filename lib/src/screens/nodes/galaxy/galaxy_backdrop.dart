/// The galaxy's sky: a backdrop rendered once per size and theme (ground,
/// nebula, vignette), and three layers of stars that move against the camera.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'galaxy_native.dart';

/// The nebula program, loaded once; null where shaders are unavailable.
final Future<ui.FragmentProgram?> _program = ui.FragmentProgram.fromAsset(
  'shaders/nebula.frag',
).then<ui.FragmentProgram?>((p) => p, onError: (_) => null);

/// The sky's ground colours, drawn from the theme so the galaxy sits inside
/// the app's own palette: a night sky in dark mode, a pale orrery in light.
({Color top, Color bottom, Color glow}) skyColors(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  return dark
      ? (
          top: Color.lerp(const Color(0xFF06070A), scheme.primary, 0.05)!,
          bottom: Color.lerp(const Color(0xFF0E1015), scheme.primary, 0.08)!,
          glow: Color.lerp(const Color(0xFF1A1C24), scheme.primary, 0.14)!,
        )
      : (
          top: Color.lerp(scheme.surfaceContainerLowest, scheme.primary, 0.02)!,
          bottom: Color.lerp(scheme.surfaceContainer, scheme.primary, 0.04)!,
          glow: Colors.white,
        );
}

/// Paint the ground without the nebula: what shows until the image is
/// ready, and where shaders are unavailable.
void paintGround(Canvas canvas, Size size, ColorScheme scheme) {
  final colors = skyColors(scheme);
  final dark = scheme.brightness == Brightness.dark;
  final rect = Offset.zero & size;
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [colors.top, colors.bottom],
      ).createShader(rect),
  );
  // Lit from the centre of the disk.
  canvas.drawRect(
    rect,
    Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, 0.1),
        radius: 0.8,
        colors: [
          colors.glow.withValues(alpha: dark ? 0.6 : 0.85),
          colors.glow.withValues(alpha: 0),
        ],
      ).createShader(rect),
  );
}

/// The backdrop image for one size and palette, rendered once.
class BackdropCache {
  Backdrop? _current;
  bool _enabled = true;

  set enabled(bool enabled) {
    _enabled = enabled;
    if (!enabled) dispose();
  }

  Backdrop? of(
    Size size,
    ColorScheme scheme,
    double ratio,
    VoidCallback ready,
  ) {
    if (!_enabled) return null;
    final current = _current;
    if (current != null &&
        current.size == size &&
        current.scheme == scheme &&
        current.ratio == ratio) {
      return current.._ready = ready;
    }
    dispose();
    final next = _current = Backdrop._(size, scheme, ratio).._ready = ready;
    next._render();
    return next;
  }

  void dispose() {
    _current?._dispose();
    _current = null;
  }
}

class Backdrop {
  Backdrop._(this.size, this.scheme, this.ratio);

  final Size size;
  final ColorScheme scheme;
  final double ratio;

  ui.Image? _image;
  bool _disposed = false;

  /// Wakes the owning canvas when its image is ready; cleared on disposal.
  VoidCallback? _ready;

  Future<void> _render() async {
    final program = await _program;
    if (_disposed || size.isEmpty) return;
    // Half resolution is plenty for smoke and keeps the render quick.
    final scale = math.min(ratio, 1.5) * 0.5;
    final width = math.max(1, (size.width * scale).round());
    final height = math.max(1, (size.height * scale).round());
    final dark = scheme.brightness == Brightness.dark;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    ui.FragmentShader? shader;
    canvas.scale(scale);
    paintGround(canvas, size, scheme);
    if (program != null) {
      final tint = scheme.primary;
      shader = program.fragmentShader()
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, 23.0)
        ..setFloat(3, dark ? 1 : 0)
        ..setFloat(4, tint.r)
        ..setFloat(5, tint.g)
        ..setFloat(6, tint.b);
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    }
    // A vignette keeps the eye on the disk.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          radius: 0.95,
          colors: [
            Colors.transparent,
            (dark ? Colors.black : scheme.outline).withValues(
              alpha: dark ? 0.55 : 0.08,
            ),
          ],
          stops: const [0.55, 1],
        ).createShader(Offset.zero & size),
    );
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      if (_disposed) {
        image.dispose();
        return;
      }
      _image = image;
      _ready?.call();
    } catch (_) {
      // No rasteriser (tests): the ground is painted live instead.
    } finally {
      picture.dispose();
      shader?.dispose();
    }
  }

  void _dispose() {
    _disposed = true;
    _ready = null;
    _image?.dispose();
    _image = null;
  }

  /// Draw it, or the plain ground until it is ready.
  void paint(Canvas canvas) {
    final image = _image;
    if (image == null) {
      paintGround(canvas, size, scheme);
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }
}

/// One layer of stars: unit positions in brightness buckets, so they
/// twinkle without a paint per star.
class _StarLayer {
  _StarLayer(this.points, this.parallax, this.size, this.phases);

  /// Per bucket: interleaved unit x, y.
  final List<Float32List> points;
  final double parallax;
  final double size;
  final List<double> phases;
}

/// Three layers of stars, far to near, with a slow twinkle.
class Starfield {
  Starfield() : _layers = _generate() {
    _native = NativeStarBatch([
      for (final layer in _layers)
        for (final points in layer.points) (points, layer.parallax),
    ]);
    if (_native.usesNative) {
      var index = 0;
      for (final layer in _layers) {
        for (var bucket = 0; bucket < layer.points.length; bucket++) {
          layer.points[bucket] = _native.points[index++];
        }
      }
    }
  }
  late final NativeStarBatch _native;
  void dispose() => _native.dispose();

  final List<_StarLayer> _layers;
  final Float32List _scratch = Float32List(2 * 400);

  static List<_StarLayer> _generate() {
    final random = math.Random(4242);
    _StarLayer layer(int count, double parallax, double size) {
      final buckets = List.generate(4, (_) => <double>[]);
      for (var i = 0; i < count; i++) {
        buckets[i % 4]
          ..add(random.nextDouble())
          ..add(random.nextDouble());
      }
      return _StarLayer(
        [for (final b in buckets) Float32List.fromList(b)],
        parallax,
        size,
        [for (var i = 0; i < 4; i++) random.nextDouble() * math.pi * 2],
      );
    }

    return [layer(320, 0.12, 0.9), layer(150, 0.3, 1.35), layer(56, 0.62, 2.0)];
  }

  /// Paint every layer, shifted by the camera's [yaw] and [tilt].
  void paint(
    Canvas canvas,
    Size size,
    double yaw,
    double tilt,
    double time, {
    required bool dark,
    required bool still,
  }) {
    _native.project(size, yaw, tilt);
    final base = dark ? Colors.white : const Color(0xFF2A2A2E);
    for (final layer in _layers) {
      final shiftX = (yaw / (math.pi * 2)) * size.width * layer.parallax * 2.2;
      final shiftY = (tilt - 0.6) * size.height * layer.parallax * 0.6;
      for (var b = 0; b < layer.points.length; b++) {
        final source = layer.points[b];
        final count = source.length ~/ 2;
        final out = _native.usesNative
            ? source
            : count * 2 <= _scratch.length
            ? Float32List.sublistView(_scratch, 0, count * 2)
            : Float32List(count * 2);
        for (var i = 0; !_native.usesNative && i < count; i++) {
          final x = (source[i * 2] * size.width + shiftX) % size.width;
          final y = (source[i * 2 + 1] * size.height + shiftY) % size.height;
          out[i * 2] = x < 0 ? x + size.width : x;
          out[i * 2 + 1] = y < 0 ? y + size.height : y;
        }
        final twinkle = still
            ? 0.8
            : 0.7 + 0.3 * math.sin(time * (0.6 + b * 0.23) + layer.phases[b]);
        final strength = dark
            ? 0.32 + layer.parallax * 0.75
            : 0.08 + layer.parallax * 0.26;
        canvas.drawRawPoints(
          ui.PointMode.points,
          out,
          Paint()
            ..color = base.withValues(alpha: (strength * twinkle).clamp(0, 1))
            ..strokeWidth = layer.size
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }
}
