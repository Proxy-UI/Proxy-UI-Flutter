/// A small lit sphere: how a node looks wherever it appears, in the galaxy,
/// in the list or in a legend. Its colour is the node's health.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Paint one sphere of [radius] at [center], lit from the upper left.
///
/// Dark themes let it glow in its colour; light themes give it a glossy
/// ceramic body with a soft contact shadow, which reads on a pale sky.
void paintPlanet(
  Canvas canvas,
  Offset center,
  double radius,
  Color color, {
  required bool dark,
  double glow = 1,
  double opacity = 1,
}) => paintSphere(
  CanvasSphereLayers(canvas),
  center,
  radius,
  color,
  dark: dark,
  glow: glow,
  opacity: opacity,
);

/// [paintPlanet] onto [layers]: each layer keeps its own opacity, so a faded
/// sphere stays as translucent as its parts.
void paintSphere(
  SphereLayers layers,
  Offset center,
  double radius,
  Color color, {
  required bool dark,
  double glow = 1,
  double opacity = 1,
}) {
  if (radius <= 0 || opacity <= 0) return;
  final alpha = opacity.clamp(0.0, 1.0);
  if (dark && glow > 0) {
    layers.softDisc(
      center,
      radius * 1.7,
      radius * 1.1,
      color.withValues(alpha: 0.32 * glow * alpha),
    );
  } else if (!dark) {
    layers.contactShadow(
      center,
      radius,
      Colors.black.withValues(alpha: 0.10 * alpha),
    );
  }
  layers.body(center, radius, color, dark: dark, alpha: alpha);
  paintSphereLight(layers, center, radius, dark: dark, opacity: alpha);
}

/// The rim light and specular point that make a disc read as a sphere,
/// drawn over whatever the body is (a colour or a flag).
void paintSphereLight(
  SphereLayers layers,
  Offset center,
  double radius, {
  required bool dark,
  double opacity = 1,
}) {
  layers.rim(
    center,
    radius,
    math.max(0.6, radius * 0.08),
    (dark ? 0.22 : 0.5) * opacity,
  );
  layers.softDisc(
    center + Offset(-radius * 0.36, -radius * 0.40),
    radius * 0.18,
    radius * 0.12,
    Colors.white.withValues(alpha: (dark ? 0.55 : 0.8) * opacity),
  );
}

/// Where a sphere's layers go: straight onto a canvas
/// ([CanvasSphereLayers]), or from images rendered once (the galaxy's
/// planet atlas).
abstract interface class SphereLayers {
  /// A disc of [radius] blurred by [sigma], in [color]: glows and halos.
  void softDisc(Offset center, double radius, double sigma, Color color);

  /// The shadow a sphere of [radius] at [center] casts on the plane beneath.
  void contactShadow(Offset center, double radius, Color color);

  /// The sphere's body in [color], lit from the upper left, at [alpha].
  void body(
    Offset center,
    double radius,
    Color color, {
    required bool dark,
    required double alpha,
  });

  /// A white rim light of [width], brightest on the far side, at [alpha].
  void rim(Offset center, double radius, double width, double alpha);
}

/// The oval of the shadow a sphere of [radius] at [center] casts on the plane
/// beneath, and its blur.
({Rect oval, double sigma}) contactShadowShape(Offset center, double radius) =>
    (
      oval: Rect.fromCenter(
        center: center + Offset(radius * 0.15, radius * 0.95),
        width: radius * 1.9,
        height: radius * 0.55,
      ),
      sigma: radius * 0.35,
    );

/// Sphere layers drawn as vectors onto [canvas].
class CanvasSphereLayers implements SphereLayers {
  const CanvasSphereLayers(this.canvas);

  final Canvas canvas;

  @override
  void softDisc(Offset center, double radius, double sigma, Color color) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
    );
  }

  @override
  void contactShadow(Offset center, double radius, Color color) {
    final shape = contactShadowShape(center, radius);
    canvas.drawOval(
      shape.oval,
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, shape.sigma),
    );
  }

  @override
  void body(
    Offset center,
    double radius,
    Color color, {
    required bool dark,
    required double alpha,
  }) {
    final highlight = Color.lerp(color, Colors.white, dark ? 0.55 : 0.7)!;
    final shade = Color.lerp(color, Colors.black, dark ? 0.6 : 0.32)!;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.38, -0.42),
          radius: 1.05,
          colors: [
            highlight.withValues(alpha: alpha),
            color.withValues(alpha: alpha),
            shade.withValues(alpha: alpha),
          ],
          stops: const [0, 0.48, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  void rim(Offset center, double radius, double width, double alpha) {
    canvas.drawCircle(
      center,
      radius * 0.94,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = SweepGradient(
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: alpha),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0.05, 0.22, 0.42],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }
}

/// A sphere in a square box.
class PlanetGlyph extends StatelessWidget {
  const PlanetGlyph({
    super.key,
    required this.color,
    this.size = 20,
    this.ring = false,
  });

  final Color color;

  /// Edge of the box.
  final double size;

  /// Draw a halo ring, as the galaxy does for the connected node.
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _PlanetPainter(color: color, dark: dark, ring: ring),
      ),
    );
  }
}

class _PlanetPainter extends CustomPainter {
  _PlanetPainter({required this.color, required this.dark, required this.ring});

  final Color color;
  final bool dark;
  final bool ring;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * (ring ? 0.26 : 0.32);
    if (ring) {
      canvas.drawCircle(
        center,
        size.shortestSide * 0.44,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = color.withValues(alpha: 0.7),
      );
    }
    paintPlanet(canvas, center, radius, color, dark: dark, glow: 0.6);
  }

  @override
  bool shouldRepaint(_PlanetPainter old) =>
      old.color != color || old.dark != dark || old.ring != ring;
}
