import 'dart:ffi' hide Size;
import 'dart:typed_data';
import 'dart:ui';

import 'package:ffi/ffi.dart';

import '../../../ffi/proxy_ffi.dart';
import 'galaxy_camera.dart';
import 'galaxy_model.dart';
import 'galaxy_view.dart';

void writeGalaxyCamera(Float64List values, Projection p, Rect viewport) {
  values[0] = p.eye.x;
  values[1] = p.eye.y;
  values[2] = p.eye.z;
  values[3] = p.right.x;
  values[4] = p.right.y;
  values[5] = p.right.z;
  values[6] = p.up.x;
  values[7] = p.up.y;
  values[8] = p.up.z;
  values[9] = p.forward.x;
  values[10] = p.forward.y;
  values[11] = p.forward.z;
  values[12] = p.center.dx;
  values[13] = p.center.dy;
  values[14] = p.focal;
  values[15] = 0.2;
  values[16] = viewport.left;
  values[17] = viewport.top;
  values[18] = viewport.right;
  values[19] = viewport.bottom;
}

typedef _BodiesNative = Int32 Function(
  Pointer<Double>,
  Pointer<Double>,
  Uint32,
  Pointer<Double>,
  Double,
  Double,
);
typedef _Bodies = int Function(
  Pointer<Double>,
  Pointer<Double>,
  int,
  Pointer<Double>,
  double,
  double,
);
typedef _StarsNative = Int32 Function(
  Pointer<Float>,
  Uint32,
  Pointer<Float>,
  Double,
  Double,
  Double,
  Double,
);
typedef _Stars = int Function(
  Pointer<Float>,
  int,
  Pointer<Float>,
  double,
  double,
  double,
  double,
);

/// Stable body parameters and outputs remain in native memory across frames.
/// Only animation timestamps change; Dart creates presentation objects solely
/// for visible planets after Rust has done orbit and projection arithmetic.
class NativeBodyBatch {
  NativeBodyBatch(
    GalaxyScene scene, {
    DynamicLibrary? library,
    bool useNative = true,
  }) {
    final entries = [
      for (final system in scene.systems)
        for (final planet in system.planets) (system, planet),
    ];
    if (!useNative || entries.length > 10000) return;
    try {
      _place = (library ?? ProxyFFI().lib)
          .lookupFunction<_BodiesNative, _Bodies>(
            'proxy_galaxy_place_bodies_v1',
            isLeaf: true,
          );
    } catch (_) {
      return;
    }
    _camera = calloc<Double>(20);
    _cameraValues = _camera!.asTypedList(20);
    _input = calloc<Double>(entries.length * 13);
    _output = calloc<Double>(entries.length * 8);
    _parameters = _input!.asTypedList(entries.length * 13);
    _placed = _output!.asTypedList(entries.length * 8);
    for (var i = 0; i < entries.length; i++) {
      final (system, planet) = entries[i];
      final id = planet.id;
      _ids.add(id);
      _index[id] = i;
      _parameters!.setAll(i * 13, [
        system.position.x,
        system.position.y,
        system.position.z,
        planet.radius,
        planet.phase,
        planet.period,
        planet.tiltAxis,
        planet.tilt,
        double.nan,
        0,
        0,
        0,
        double.nan,
      ]);
    }
  }
  final _ids = <String>[];
  final _index = <String, int>{};
  _Bodies? _place;
  Pointer<Double>? _camera, _input, _output;
  Float64List? _cameraValues, _parameters, _placed;
  bool get usesNative => _place != null;

  void project(
    Projection projection,
    Size size,
    double orbitTime,
    double time,
    Map<String, double> appeared,
    Map<String, Migration> migrations,
  ) {
    if (!usesNative) return;
    writeGalaxyCamera(_cameraValues!, projection, Offset.zero & size);
    for (var i = 0; i < _ids.length; i++) {
      final id = _ids[i];
      final since = appeared[id];
      if (since != null && time - since >= 1.6) appeared.remove(id);
      _parameters![i * 13 + 8] = appeared[id] ?? double.nan;
      var migration = migrations[id];
      if (migration != null && time - migration.since >= Migration.duration) {
        migrations.remove(id);
        migration = null;
      }
      _parameters![i * 13 + 12] = migration?.since ?? double.nan;
      if (migration != null) {
        _parameters![i * 13 + 9] = migration.from.x;
        _parameters![i * 13 + 10] = migration.from.y;
        _parameters![i * 13 + 11] = migration.from.z;
      }
    }
    final result = _place!(
      _camera!,
      _input!,
      _ids.length,
      _output!,
      orbitTime,
      time,
    );
    if (result != 0) {
      throw StateError('Invalid native body projection: $result');
    }
  }

  (Projected, double)? placed(String id, Rect viewport) {
    final index = _index[id];
    if (index == null) return null;
    final offset = index * 8;
    final values = _placed!;
    if (values[offset + 5] <= 0) return null;
    final point = Offset(values[offset + 3], values[offset + 4]);
    if (!viewport.contains(point)) return null;
    return (
      (point: point, scale: values[offset + 5], depth: values[offset + 6]),
      values[offset + 7],
    );
  }

  void dispose() {
    if (_camera != null) calloc.free(_camera!);
    if (_input != null) calloc.free(_input!);
    if (_output != null) calloc.free(_output!);
    _camera = _input = _output = null;
    _cameraValues = _parameters = _placed = null;
    _place = null;
    _ids.clear();
    _index.clear();
  }
}

class NativeStarBatch {
  NativeStarBatch(
    List<(Float32List, double)> buckets, {
    DynamicLibrary? library,
  }) {
    try {
      _place = (library ?? ProxyFFI().lib).lookupFunction<_StarsNative, _Stars>(
        'proxy_galaxy_place_stars_v1',
        isLeaf: true,
      );
    } catch (_) {
      return;
    }
    _count = buckets.fold(0, (sum, bucket) => sum + bucket.$1.length ~/ 2);
    _input = calloc<Float>(_count * 3);
    _output = calloc<Float>(_count * 2);
    final parameters = _input!.asTypedList(_count * 3);
    var offset = 0;
    for (final (source, parallax) in buckets) {
      final count = source.length ~/ 2;
      points.add((_output! + offset * 2).asTypedList(count * 2));
      for (var i = 0; i < count; i++) {
        parameters[(offset + i) * 3] = source[i * 2];
        parameters[(offset + i) * 3 + 1] = source[i * 2 + 1];
        parameters[(offset + i) * 3 + 2] = parallax;
      }
      offset += count;
    }
  }
  final points = <Float32List>[];
  _Stars? _place;
  Pointer<Float>? _input, _output;
  int _count = 0;
  bool get usesNative => _place != null;
  void project(Size size, double yaw, double tilt) {
    if (!usesNative) return;
    final result = _place!(
      _input!,
      _count,
      _output!,
      size.width,
      size.height,
      yaw,
      tilt,
    );
    if (result != 0) {
      throw StateError('Invalid native star projection: $result');
    }
  }

  void dispose() {
    if (_input != null) calloc.free(_input!);
    if (_output != null) calloc.free(_output!);
    _input = _output = null;
    _place = null;
    points.clear();
  }
}
