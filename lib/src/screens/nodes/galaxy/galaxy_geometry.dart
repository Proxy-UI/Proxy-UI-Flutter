import 'dart:ffi' hide Size;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:ffi/ffi.dart';

import '../../../ffi/proxy_ffi.dart';
import 'galaxy_camera.dart';
import 'galaxy_model.dart';
import 'galaxy_native.dart';
import 'galaxy_view.dart';

typedef WorldLine = ({Vec3 start, Vec3 end, int group});
typedef _ProjectNative = Int32 Function(
  Pointer<Double>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Float>,
  Uint32,
);
typedef _Project = int Function(
  Pointer<Double>,
  Pointer<Uint8>,
  int,
  Pointer<Float>,
  int,
);

/// One bounded leaf call per frame. Dart owns and reuses both native buffers.
/// Older libraries and widget tests use the same clipped geometry in Dart.
class GeometryBatch {
  GeometryBatch(
    List<WorldLine> lines, {
    DynamicLibrary? library,
    bool useNative = true,
  }) : _count = lines.length {
    _project = useNative && lines.length <= 100000
        ? (library == null ? _native : _lookup(library))
        : null;
    if (_project != null && lines.isNotEmpty) {
      _camera = calloc<Double>(20);
      _input = calloc<Uint8>(lines.length * 56);
      _output = calloc<Float>(lines.length * 6);
      final bytes = _input!.asTypedList(lines.length * 56);
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final values = [
          line.start.x,
          line.start.y,
          line.start.z,
          line.end.x,
          line.end.y,
          line.end.z,
        ];
        for (var j = 0; j < 6; j++) {
          data.setFloat64(i * 56 + j * 8, values[j], Endian.host);
        }
        data.setUint32(i * 56 + 48, line.group, Endian.host);
      }
      coordinates = _output!.asTypedList(lines.length * 6);
    } else {
      coordinates = Float32List(lines.length * 6);
    }
    _fallbackLines = _project == null ? lines : const [];
    groups = Uint32List.view(coordinates.buffer, coordinates.offsetInBytes);
  }

  static _Project? _lookup(DynamicLibrary library) {
    try {
      return library.lookupFunction<_ProjectNative, _Project>(
        'proxy_galaxy_project_segments_v1',
        isLeaf: true,
      );
    } on ArgumentError {
      return null;
    }
  }

  static final _Project? _native = _load();
  static _Project? _load() {
    try {
      return _lookup(ProxyFFI().lib);
    } catch (_) {
      return null;
    }
  }

  static bool get nativeAvailable => _native != null;
  bool get usesNative => _project != null;
  final int _count;
  late final List<WorldLine> _fallbackLines;
  _Project? _project;
  Pointer<Double>? _camera;
  Pointer<Uint8>? _input;
  Pointer<Float>? _output;
  late final Float32List coordinates;
  late final Uint32List groups;
  bool _disposed = false;

  int project(Projection projection, Rect viewport) {
    if (_disposed) throw StateError('Disposed geometry batch');
    if (_count == 0) return 0;
    if (_project case final project?) {
      writeGalaxyCamera(_camera!.asTypedList(20), projection, viewport);
      final count = project(_camera!, _input!, _count, _output!, _count);
      if (count >= 0) return count;
      throw StateError('Galaxy projection rejected its buffers: $count');
    }
    var count = 0;
    for (final line in _fallbackLines) {
      final clipped = clipWorldLine(line.start, line.end, projection, viewport);
      if (clipped == null) continue;
      final i = count++ * 6;
      coordinates[i] = clipped.start.dx;
      coordinates[i + 1] = clipped.start.dy;
      coordinates[i + 2] = clipped.end.dx;
      coordinates[i + 3] = clipped.end.dy;
      groups[i + 4] = line.group;
      coordinates[i + 5] = clipped.depth;
    }
    return count;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_camera != null) calloc.free(_camera!);
    if (_input != null) calloc.free(_input!);
    if (_output != null) calloc.free(_output!);
  }
}

/// Near-plane and Liang–Barsky clipping, also used for the moving link.
({Offset start, Offset end, double depth})? clipWorldLine(
  Vec3 start,
  Vec3 end,
  Projection projection,
  Rect viewport,
) {
  Vec3 transform(Vec3 v) {
    final relative = v - projection.eye;
    return Vec3(
      relative.dot(projection.right),
      relative.dot(projection.up),
      relative.dot(projection.forward),
    );
  }

  var a = transform(start), b = transform(end);
  if (![a.x, a.y, a.z, b.x, b.y, b.z].every((v) => v.isFinite)) return null;
  const near = 0.2;
  if (a.z < near && b.z < near) return null;
  if (a.z < near) {
    final clipped = a.lerp(b, (near - a.z) / (b.z - a.z));
    a = Vec3(clipped.x, clipped.y, near);
  } else if (b.z < near) {
    final clipped = b.lerp(a, (near - b.z) / (a.z - b.z));
    b = Vec3(clipped.x, clipped.y, near);
  }
  final x0 = projection.center.dx + a.x * projection.focal / a.z;
  final y0 = projection.center.dy - a.y * projection.focal / a.z;
  final dx = projection.center.dx + b.x * projection.focal / b.z - x0;
  final dy = projection.center.dy - b.y * projection.focal / b.z - y0;
  if (![x0, y0, dx, dy].every((v) => v.isFinite)) return null;
  var enter = 0.0, leave = 1.0;
  for (final (p, q) in [
    (-dx, x0 - viewport.left),
    (dx, viewport.right - x0),
    (-dy, y0 - viewport.top),
    (dy, viewport.bottom - y0),
  ]) {
    if (p == 0) {
      if (q < 0) return null;
    } else {
      final t = q / p;
      if (p < 0) {
        enter = math.max(enter, t);
      } else {
        leave = math.min(leave, t);
      }
      if (enter > leave) return null;
    }
  }
  Offset at(double t) => Offset(
    (x0 + dx * t).clamp(viewport.left, viewport.right),
    (y0 + dy * t).clamp(viewport.top, viewport.bottom),
  );
  return (start: at(enter), end: at(leave), depth: (a.z + b.z) / 2);
}

/// Reused GPU line batch; dashes are generated only after viewport clipping.
class GalaxyLines {
  GalaxyLines(int capacity) : _points = Float32List(capacity * 4);
  final Float32List _points;
  int _length = 0;
  void clear() => _length = 0;
  void add(double x0, double y0, double x1, double y1) {
    _points[_length++] = x0;
    _points[_length++] = y0;
    _points[_length++] = x1;
    _points[_length++] = y1;
  }

  void draw(Canvas canvas, Paint paint, {bool dashed = false}) {
    if (_length == 0) return;
    final points = Float32List.sublistView(_points, 0, _length);
    if (!dashed) {
      canvas.drawRawPoints(PointMode.lines, points, paint);
      return;
    }
    final path = Path();
    var phase = 0.0;
    for (var i = 0; i < _length; i += 4) {
      final dx = points[i + 2] - points[i], dy = points[i + 3] - points[i + 1];
      final length = math.sqrt(dx * dx + dy * dy);
      if (length < 1e-5) continue;
      for (var d = -phase; d < length; d += 9) {
        final start = math.max(0.0, d), end = math.min(length, d + 5);
        if (end <= start) continue;
        path.moveTo(
          points[i] + dx * start / length,
          points[i + 1] + dy * start / length,
        );
        path.lineTo(
          points[i] + dx * end / length,
          points[i + 1] + dy * end / length,
        );
      }
      phase = (phase + length) % 9;
    }
    canvas.drawPath(path, paint..style = PaintingStyle.stroke);
  }
}

/// World geometry changes with the scene, never with camera motion or zoom.
class GalaxyGeometry {
  GalaxyScene? _scene;
  GeometryBatch? _batch;
  NativeBodyBatch? bodies;
  final guides = <GalaxyLines>[];
  final orbits = <String, ({GalaxyLines back, GalaxyLines front})>{};
  final _systems = <CountrySystem>[];

  void project(
    GalaxyScene scene,
    Projection projection,
    Size size, {
    GalaxyView? view,
  }) {
    if (!identical(scene, _scene)) {
      if (_sameLayout(scene)) {
        _scene = scene;
        _systems
          ..clear()
          ..addAll(scene.systems);
      } else {
        _build(scene);
      }
    }
    if (view != null) {
      bodies?.project(
        projection,
        size,
        view.orbitTime,
        view.time,
        view.appeared,
        view.migrations,
      );
    }
    for (final guide in guides) {
      guide.clear();
    }
    for (final orbit in orbits.values) {
      orbit.back.clear();
      orbit.front.clear();
    }
    final depths = [
      for (final system in _systems)
        (system.position - projection.eye).dot(projection.forward),
    ];
    final batch = _batch!;
    final count = batch.project(projection, (Offset.zero & size).inflate(2));
    final points = batch.coordinates;
    for (var i = 0; i < count * 6; i += 6) {
      final group = batch.groups[i + 4];
      final GalaxyLines target;
      if (group < 6) {
        target = guides[group];
      } else {
        final index = group - 6;
        final orbit = orbits[_systems[index].id]!;
        target = points[i + 5] > depths[index] ? orbit.back : orbit.front;
      }
      target.add(points[i], points[i + 1], points[i + 2], points[i + 3]);
    }
  }

  bool _sameLayout(GalaxyScene scene) {
    final previous = _scene;
    if (previous == null ||
        previous.reach != scene.reach ||
        previous.systems.length != scene.systems.length) {
      return false;
    }
    for (var i = 0; i < scene.systems.length; i++) {
      final a = previous.systems[i], b = scene.systems[i];
      if (a.code != b.code ||
          a.position.x != b.position.x ||
          a.position.y != b.position.y ||
          a.position.z != b.position.z ||
          a.planets.length != b.planets.length) {
        return false;
      }
      for (var j = 0; j < a.planets.length; j++) {
        final p = a.planets[j], q = b.planets[j];
        if (p.id != q.id ||
            p.ring != q.ring ||
            p.radius != q.radius ||
            p.phase != q.phase ||
            p.period != q.period ||
            p.tiltAxis != q.tiltAxis ||
            p.tilt != q.tilt) {
          return false;
        }
      }
    }
    return true;
  }

  void _build(GalaxyScene scene) {
    dispose();
    _scene = scene;
    bodies = NativeBodyBatch(scene);
    final lines = <WorldLine>[];
    void circle(int group, Vec3 Function(double) point, int segments) {
      var start = point(0);
      for (var i = 1; i <= segments; i++) {
        final end = point(i * math.pi * 2 / segments);
        lines.add((start: start, end: end, group: group));
        start = end;
      }
    }

    final reach = math.max(scene.reach, latitudeRadius(-30));
    const latitudes = [60.0, 30.0, 0.0, -30.0, -60.0];
    for (var i = 0; i < latitudes.length; i++) {
      guides.add(GalaxyLines(120));
      final radius = latitudeRadius(latitudes[i]);
      if (radius > reach * 1.08) continue;
      circle(
        i,
        (a) => Vec3(math.cos(a) * radius, 0, math.sin(a) * radius),
        120,
      );
    }
    guides.add(GalaxyLines(12));
    final inner = latitudeRadius(75),
        outer = math.min(reach, latitudeRadius(-60));
    for (var lon = 0; lon < 360; lon += 30) {
      final theta = lon * math.pi / 180;
      lines.add((
        start: Vec3(math.sin(theta) * inner, 0, math.cos(theta) * inner),
        end: Vec3(math.sin(theta) * outer, 0, math.cos(theta) * outer),
        group: 5,
      ));
    }
    for (final system in scene.systems) {
      final group = 6 + _systems.length;
      _systems.add(system);
      final rings = <int, NodePlanet>{};
      for (final planet in system.planets) {
        rings.putIfAbsent(planet.ring, () => planet);
      }
      final capacity = rings.length * 96;
      orbits[system.id] = (
        back: GalaxyLines(capacity),
        front: GalaxyLines(capacity),
      );
      for (final planet in rings.values) {
        circle(
          group,
          (a) =>
              system.position +
              tiltAround(
                Vec3(
                  math.cos(a) * planet.radius,
                  0,
                  math.sin(a) * planet.radius,
                ),
                planet.tiltAxis,
                planet.tilt,
              ),
          96,
        );
      }
    }
    _batch = GeometryBatch(lines);
  }

  void dispose() {
    bodies?.dispose();
    bodies = null;
    _batch?.dispose();
    _batch = null;
    _scene = null;
    guides.clear();
    orbits.clear();
    _systems.clear();
  }
}
