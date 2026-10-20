// The galaxy's cached sprites must paint what the vector layers paint:
// spheres and flag spheres of the sizes the galaxy draws, opaque and faded,
// in both themes, overlapping vector strokes, plus glows drawn as soft discs.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/planet_atlas.dart';
import 'package:proxy_ui/src/widgets/planet_glyph.dart';

const _ratio = 2.0;
const _size = Size(460, 300);

/// Spheres, flags and glows in a grid through [layers]; [between] paints a
/// vector stroke over each first sphere and under the next.
void _scene(
  FlagSphereLayers layers,
  ui.Image flag,
  bool dark,
  void Function(Offset center) between,
) {
  const colors = [Color(0xFF3FB950), Color(0xFFE5534B), Color(0xFF8E8E8A)];
  const radii = [2.4, 4.4, 7.3, 14.0, 26.0];
  var x = 30.0;
  for (final radius in radii) {
    var y = 30.0;
    for (final (i, opacity) in [1.0, 0.62, 0.3].indexed) {
      final c = Offset(x, y);
      paintSphere(
        layers,
        c,
        radius,
        colors[i],
        dark: dark,
        glow: i == 2 ? 0 : 0.9,
        opacity: opacity,
      );
      between(c);
      // An overlapping neighbour: sprites must keep the painting order.
      paintSphere(
        layers,
        c + Offset(radius * 0.8, radius * 0.5),
        radius * 0.7,
        colors[(i + 1) % 3],
        dark: dark,
        opacity: opacity,
      );
      y += 70;
    }
    paintFlagSphere(layers, 'XX', flag, Offset(x, y), radius, dark: dark);
    x += radius * 2 + 44;
  }
  layers.softDisc(
    const Offset(380, 230),
    60,
    30,
    colors[0].withValues(alpha: 0.16),
  );
}

Future<ui.Image> _flag() {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var i = 0; i < 4; i++) {
    canvas.drawRect(
      Rect.fromLTWH(0, i * 32.0, 128, 32),
      Paint()..color = i.isEven ? const Color(0xFFB22234) : Colors.white,
    );
  }
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 56, 64),
    Paint()..color = const Color(0xFF3C3B6E),
  );
  return recorder.endRecording().toImage(128, 128);
}

Future<Uint8List> _pixels(void Function(Canvas canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(_ratio);
  canvas.drawColor(const Color(0xFF808080), BlendMode.src);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (_size.width * _ratio).round(),
    (_size.height * _ratio).round(),
  );
  final data = await image.toByteData();
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// The share of channels differing by more than 8/255.
double _off(Uint8List a, Uint8List b) {
  var off = 0;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 8) off++;
  }
  return off / a.length;
}

/// Vector layers whose bodies ignore their opacity: a real mismatch.
class _OpaqueBodies extends CanvasFlagSphereLayers {
  const _OpaqueBodies(super.canvas);

  @override
  void body(
    Offset center,
    double radius,
    Color color, {
    required bool dark,
    required double alpha,
  }) => super.body(center, radius, color, dark: dark, alpha: 1);
}

void main() {
  for (final dark in [false, true]) {
    test(
      'sprites paint the vector layers (${dark ? 'dark' : 'light'})',
      () async {
        final flag = await _flag();
        final atlas = PlanetAtlas()
          ..palette(const ColorScheme.dark())
          ..enabled = true;
        addTearDown(() {
          atlas.dispose();
          flag.dispose();
        });
        void ring(Canvas canvas, Offset c) => canvas.drawCircle(
          c,
          5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = Colors.white,
        );
        void frame(Canvas canvas) {
          atlas.begin(canvas, ratio: _ratio);
          _scene(atlas, flag, dark, (c) {
            atlas.flush();
            ring(canvas, c);
          });
          atlas.end();
        }

        final vector = await _pixels(
          (c) => _scene(CanvasFlagSphereLayers(c), flag, dark, (o) {
            ring(c, o);
          }),
        );
        // The first frame asks for the layers and paints vectors.
        expect(await _pixels(frame), vector);
        final cached = await _pixels(frame);
        expect(cached, isNot(vector), reason: 'the second frame uses sprites');
        // Resampling a cached image moves anti-aliased edges, the stripes
        // inside a flag among them, by a fraction of a pixel (measured:
        // 0.15-0.19 % of channels). A wrong colour, size, place, order or
        // opacity differs over whole areas: bodies that ignore their opacity
        // differ in about 3 %.
        expect(_off(vector, cached), lessThan(0.0025));
        final mutated = await _pixels(
          (c) => _scene(_OpaqueBodies(c), flag, dark, (o) => ring(c, o)),
        );
        expect(_off(vector, mutated), greaterThan(0.01));
      },
    );
  }

  test('a full atlas stays bounded and is not rebuilt every frame', () {
    final atlas = PlanetAtlas()
      ..palette(const ColorScheme.dark())
      ..enabled = true;
    addTearDown(atlas.dispose);
    ui.Image? image;
    var images = 0;
    for (var frame = 0; frame < 60; frame++) {
      final recorder = ui.PictureRecorder();
      atlas.begin(Canvas(recorder), ratio: _ratio);
      // Forty new colours of large spheres a frame: far more than fit.
      for (var i = 0; i < 40; i++) {
        atlas.body(
          const Offset(50, 50),
          60,
          Color(0xFF000000 | (frame * 40 + i) * 997),
          dark: true,
          alpha: 1,
        );
      }
      atlas.end();
      recorder.endRecording().dispose();
      if (!identical(atlas.debugImage, image)) {
        image = atlas.debugImage;
        images++;
      }
    }
    expect(image!.width, 512);
    expect(image.height, lessThanOrEqualTo(2048));
    expect(images, lessThan(10), reason: 'once full, it waits to refill');
  });
}
