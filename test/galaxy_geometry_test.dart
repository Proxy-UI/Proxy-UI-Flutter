import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' hide Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_camera.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_geometry.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_model.dart';

void main() {
  final projection = Projection(
    eye: Vec3.zero,
    target: const Vec3(0, 0, 1),
    center: const Offset(50, 50),
    focal: 50,
  );
  const viewport = Rect.fromLTWH(0, 0, 100, 100);

  test('crossing lines survive clipping while hidden lines are discarded', () {
    final batch = GeometryBatch([
      (start: const Vec3(-1e6, 0, 1), end: const Vec3(1e6, 0, 1), group: 7),
      (start: const Vec3(0, 0, -1), end: const Vec3(1, 0, -2), group: 8),
      (start: const Vec3(8, 0, 1), end: const Vec3(9, 0, 1), group: 9),
    ], useNative: false);
    addTearDown(batch.dispose);
    expect(batch.project(projection, viewport), 1);
    // This camera faces +Z, so its right vector points towards -X.
    expect(
      batch.coordinates.take(4),
      orderedEquals([
        closeTo(100, 1e-5),
        closeTo(50, 1e-5),
        closeTo(0, 1e-5),
        closeTo(50, 1e-5),
      ]),
    );
    expect(batch.groups[4], 7);
    expect(batch.project(projection, viewport), 1);
    batch.dispose();
    batch.dispose();
    expect(() => batch.project(projection, viewport), throwsStateError);
  });

  test(
    'near-plane clipping retains a crossing without unbounded coordinates',
    () {
      final line = clipWorldLine(
        const Vec3(-0.1, 0, -1),
        const Vec3(0.2, 0, 2),
        projection,
        viewport,
      )!;
      expect(line.start.dx, closeTo(45, 1e-5));
      expect(line.end.dx, closeTo(45, 1e-5));
    },
  );

  final nativePath = Platform.environment['GALAXY_NATIVE_LIBRARY'];
  test(
    'real Rust FFI matches Dart clipping across zoom, pan and near-plane crossings',
    () {
      final library = DynamicLibrary.open(nativePath!);
      final random = math.Random(20261020);
      Vec3 point() => Vec3(
        random.nextDouble() * 40 - 20,
        random.nextDouble() * 40 - 20,
        random.nextDouble() * 40 - 20,
      );
      final lines = <WorldLine>[
        for (var i = 0; i < 2000; i++)
          (start: point(), end: point(), group: i % 37),
        (start: const Vec3(double.nan, 0, 0), end: Vec3.zero, group: 1),
      ];
      final native = GeometryBatch(lines, library: library);
      expect(native.usesNative, isTrue);
      final dart = GeometryBatch(lines, useNative: false);
      addTearDown(native.dispose);
      addTearDown(dart.dispose);
      for (var i = 0; i < 12; i++) {
        final p = Projection(
          eye: point(),
          target: Vec3.zero,
          center: const Offset(640, 360),
          focal: 200 + i * 300,
        );
        const viewport = Rect.fromLTWH(-2, -2, 1284, 724);
        final count = native.project(p, viewport);
        expect(count, dart.project(p, viewport));
        for (var j = 0; j < count * 6; j += 6) {
          expect(native.groups[j + 4], dart.groups[j + 4]);
          for (final offset in [0, 1, 2, 3, 5]) {
            expect(
              native.coordinates[j + offset],
              closeTo(dart.coordinates[j + offset], 0.002),
            );
          }
        }
      }
    },
    skip: nativePath == null
        ? 'Set GALAXY_NATIVE_LIBRARY to a freshly built native library'
        : false,
  );
}
