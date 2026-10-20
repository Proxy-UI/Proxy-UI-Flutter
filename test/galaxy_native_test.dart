import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/node_health.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_camera.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_geometry.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_layout.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_model.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_native.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_view.dart';

GalaxyScene fixture({NodeHealth health = NodeHealth.fast}) => buildGalaxyScene([
  for (final country in ['JP', 'SG', 'US', 'AE', 'PL', ''])
    for (var i = 0; i < 100; i++)
      GalaxyNode(
        node: NodeInfo(
          nodeId: '$country/$i',
          addr: 'proxy$i.example:1081',
          lastSeen: DateTime(2026),
          country: country,
          region: '',
        ),
        country: country,
        health: health,
        current: i == 0,
      ),
]);

void main() {
  final path = Platform.environment['CIPHERRELAY_NATIVE_TEST_LIB'];
  test(
    'native layout matches reference including coincident countries',
    () {
      final native = NativeGalaxyLayout(library: DynamicLibrary.open(path!));
      final codes = ['', 'AE', 'CN', 'HK', 'JP', 'KR', 'MO', 'PL', 'SG', 'US'];
      for (final coincident in [false, true]) {
        final seeds = {
          for (var i = 0; i < codes.length; i++)
            codes[i]: coincident ? Vec3.zero : Vec3(i * 0.2, 0, 3 + i * 0.1),
        };
        final extents = {
          for (var i = 0; i < codes.length; i++) codes[i]: 0.8 + i * 0.1,
        };
        final expected = relaxGalaxyPositions(
          codes,
          seeds,
          extents,
          useNative: false,
        );
        final actual = relaxGalaxyPositions(
          codes,
          seeds,
          extents,
          nativeLayout: native,
        );
        for (final code in codes) {
          expect(actual[code]!.x, closeTo(expected[code]!.x, 1e-9));
          expect(actual[code]!.z, closeTo(expected[code]!.z, 1e-9));
        }
        final values = [
          for (final code in codes) ...[
            seeds[code]!.x,
            seeds[code]!.z,
            extents[code]!,
          ],
        ];
        expect(
          identical(
            native.place(codes, values),
            native.place(codes, List.of(values)),
          ),
          isTrue,
        );
      }
    },
    skip: path == null
        ? 'Set CIPHERRELAY_NATIVE_TEST_LIB to the fresh library'
        : false,
  );
  test('health updates reuse orbit buffers without stale body layout', () {
    final geometry = GalaxyGeometry();
    addTearDown(geometry.dispose);
    final camera = GalaxyCamera().project(const Size(1280, 720));
    geometry.project(fixture(), camera, const Size(1280, 720));
    final bodies = geometry.bodies;
    final orbits = geometry.orbits.values.map((v) => v.back).toList();
    geometry.project(
      fixture(health: NodeHealth.unreachable),
      camera,
      const Size(1280, 720),
    );
    expect(identical(geometry.bodies, bodies), isTrue);
    expect(geometry.orbits.values.map((v) => v.back), orderedEquals(orbits));
  });
  test(
    'Rust orbit, entrance and migration match the Dart reference',
    () {
      final scene = fixture();
      final batch = NativeBodyBatch(scene, library: DynamicLibrary.open(path!));
      addTearDown(batch.dispose);
      expect(batch.usesNative, isTrue);
      final camera = GalaxyCamera();
      const size = Size(1280, 720);
      final viewport = (Offset.zero & size).inflate(140);
      for (final time in [0.0, 0.1, 0.8, 1.5, 1.799, 2.1, 50.0]) {
        camera.yaw = time / 10;
        final projection = camera.project(size);
        final appeared = <String, double>{};
        final migrations = <String, Migration>{};
        for (final system in scene.systems) {
          for (final planet in system.planets) {
            appeared[planet.id] = 0;
            migrations[planet.id] = const Migration(Vec3(0.1, 0.2, -0.3), 0);
          }
        }
        batch.project(projection, size, time * 3, time, appeared, migrations);
        for (final system in scene.systems) {
          for (final planet in system.planets) {
            final appear =
                1 - math.pow(1 - (time / 1.6).clamp(0.0, 1.0), 3).toDouble();
            var offset = planet.offsetAt(time * 3);
            final angle = (1 - appear) * math.pi;
            offset =
                Vec3(
                      offset.x * math.cos(angle) - offset.z * math.sin(angle),
                      offset.y,
                      offset.x * math.sin(angle) + offset.z * math.cos(angle),
                    ) *
                    appear +
                Vec3(0, 0.25 * (1 - appear), 0);
            var world = system.position + offset;
            if (time < Migration.duration) {
              final t = time / Migration.duration;
              final ease = t < 0.5
                  ? 4 * t * t * t
                  : 1 - math.pow(-2 * t + 2, 3) / 2;
              const from = Vec3(0.1, 0.2, -0.3);
              final lift =
                  math.sin(t * math.pi) * (0.6 + (world - from).length * 0.18);
              world = from.lerp(world, ease.toDouble()) + Vec3(0, lift, 0);
            }
            final expected = projection.at(world);
            final actual = batch.placed(planet.id, viewport);
            if (expected == null || !viewport.contains(expected.point)) {
              expect(actual, isNull);
            } else {
              expect(actual, isNotNull);
              expect(actual!.$1.point.dx, closeTo(expected.point.dx, 1e-8));
              expect(actual.$1.point.dy, closeTo(expected.point.dy, 1e-8));
              expect(actual.$1.scale, closeTo(expected.scale, 1e-8));
              expect(actual.$2, closeTo(appear, 1e-12));
            }
          }
        }
      }
    },
    skip: path == null
        ? 'Set CIPHERRELAY_NATIVE_TEST_LIB to the fresh library'
        : false,
  );
  test(
    'Rust star coordinates preserve wrapping and float precision',
    () {
      final random = math.Random(47);
      final points = Float32List.fromList(
        List.generate(1024, (_) => random.nextDouble()),
      );
      const parallax = 0.31;
      final batch = NativeStarBatch([
        (points, parallax),
      ], library: DynamicLibrary.open(path!));
      addTearDown(batch.dispose);
      expect(batch.usesNative, isTrue);
      for (final yaw in [-10.0, 0.0, 9.0]) {
        batch.project(const Size(1280, 720), yaw, -0.5);
        for (var i = 0; i < points.length; i += 2) {
          final x =
              (points[i] * 1280 + yaw / (math.pi * 2) * 1280 * parallax * 2.2) %
              1280;
          final y =
              (points[i + 1] * 720 + (-0.5 - 0.6) * 720 * parallax * 0.6) % 720;
          expect(batch.points.single[i], closeTo(x, 0.001));
          expect(batch.points.single[i + 1], closeTo(y, 0.001));
        }
      }
    },
    skip: path == null
        ? 'Set CIPHERRELAY_NATIVE_TEST_LIB to the fresh library'
        : false,
  );
}
