/// The galaxy's scene: every country with nodes as a star system and its
/// nodes as planets, laid out on a disk by where the countries are on Earth.
/// Pure data and arithmetic; nothing here paints.
library;

import 'dart:math' as math;

import '../../../models/country_atlas.dart';
import '../../../models/node_health.dart';
import '../../../models/node_model.dart';
import '../../../ffi/proxy_ffi.dart';
import 'galaxy_layout.dart';

final _nativeLayout = (() {
  try {
    return NativeGalaxyLayout(library: ProxyFFI().lib);
  } catch (_) {
    return NativeGalaxyLayout();
  }
})();

/// A point or direction in the galaxy's world (the disk is the x–z plane,
/// y points up out of it).
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x, y, z;

  static const zero = Vec3(0, 0, 0);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double k) => Vec3(x * k, y * k, z * k);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  double get length => math.sqrt(dot(this));

  Vec3 get unit {
    final l = length;
    return l == 0 ? this : this * (1 / l);
  }

  Vec3 lerp(Vec3 o, double t) => this + (o - this) * t;

  @override
  String toString() =>
      'Vec3(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, '
      '${z.toStringAsFixed(2)})';
}

/// A stable 32-bit hash of [text] (FNV-1a), so a node keeps its place between
/// visits and runs.
int stableHash(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// [hash] as a fraction in [0, 1).
double unitOf(int hash) => (hash & 0xffffff) / 0x1000000;

/// [p] rotated by [tilt] around the in-plane axis at angle [axis].
Vec3 tiltAround(Vec3 p, double axis, double tilt) {
  final k = Vec3(math.cos(axis), 0, math.sin(axis));
  final cos = math.cos(tilt), sin = math.sin(tilt);
  // Rodrigues' rotation around k.
  return p * cos + k.cross(p) * sin + k * (k.dot(p) * (1 - cos));
}

/// One node as the galaxy sees it: what it is, where its traffic leaves
/// from, and how it answered.
class GalaxyNode {
  const GalaxyNode({
    required this.node,
    required this.country,
    required this.health,
    this.current = false,
    this.latencyMs,
    this.quic = false,
    this.testedOverQuic = false,
  });

  final NodeInfo node;

  /// Two-letter code, or empty while the node's location is unknown.
  final String country;
  final NodeHealth health;

  /// Whether this is the proxy's configured upstream.
  final bool current;
  final int? latencyMs;

  String get id => node.storageKey;

  /// The address without its port or carrier, which is what people recognise
  /// a server by; the raw address when it does not parse.
  String get host => node.endpoint?.host ?? node.addr;

  /// `host:port` of the catalogue address, without its carrier.
  String get address => node.endpoint?.address ?? node.addr;

  /// [address], naming QUIC when the node serves it.
  String get label => quic ? '$address · QUIC' : address;

  /// Whether the node serves QUIC: addressed over it, or reported a QUIC
  /// endpoint. False while unknown.
  final bool quic;

  /// Whether [latencyMs] was measured over QUIC.
  final bool testedOverQuic;
}

/// One node, orbiting its country.
class NodePlanet {
  const NodePlanet({
    required this.node,
    required this.ring,
    required this.radius,
    required this.phase,
    required this.period,
    required this.size,
    required this.tiltAxis,
    required this.tilt,
  });

  final GalaxyNode node;

  /// Its ring, innermost 0.
  final int ring;

  /// Orbit radius in world units.
  final double radius;

  /// Where on the orbit it starts, in radians.
  final double phase;

  /// One orbit, in seconds.
  final double period;

  /// Body radius in world units.
  final double size;

  /// The orbit plane's tilt axis, as an angle in the disk.
  final double tiltAxis;

  /// The orbit plane's tilt, in radians.
  final double tilt;

  String get id => node.id;

  /// Its position relative to its star at time [t] (seconds).
  Vec3 offsetAt(double t) {
    final angle = phase + (t / period) * math.pi * 2;
    final flat = Vec3(math.cos(angle) * radius, 0, math.sin(angle) * radius);
    return tiltAround(flat, tiltAxis, tilt);
  }
}

/// One country: a star and its nodes.
class CountrySystem {
  const CountrySystem({
    required this.code,
    required this.position,
    required this.planets,
    required this.extent,
  });

  /// Two-letter code; empty for nodes whose location is unknown.
  final String code;

  /// Where its star sits.
  final Vec3 position;
  final List<NodePlanet> planets;

  /// The radius its outermost orbit reaches.
  final double extent;

  bool get unknown => code.isEmpty;

  String get id => systemIdFor(code);

  /// How many of its nodes are in each state.
  Map<NodeHealth, int> get counts {
    final counts = <NodeHealth, int>{};
    for (final planet in planets) {
      counts.update(planet.node.health, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  int get available =>
      planets.where((planet) => planet.node.health.isAvailable).length;

  /// The fastest answer among its nodes.
  int? get bestLatency {
    int? best;
    for (final planet in planets) {
      final latency = planet.node.latencyMs;
      if (!planet.node.health.isAvailable || latency == null) continue;
      if (best == null || latency < best) best = latency;
    }
    return best;
  }

  CountrySystem withPlanets(List<NodePlanet> planets) => CountrySystem(
    code: code,
    position: position,
    planets: planets,
    extent: extent,
  );
}

/// The body id of the system for [code].
String systemIdFor(String code) => 'country:$code';

/// The body id of the device in the user's hand, at the centre.
const String homeId = 'home';

/// Everything the galaxy shows.
class GalaxyScene {
  const GalaxyScene({required this.systems, this.connected = false});

  static const empty = GalaxyScene(systems: []);

  final List<CountrySystem> systems;

  /// Whether traffic is flowing through the current node, rather than the
  /// node merely being the configured upstream of a stopped proxy.
  final bool connected;

  bool get isEmpty => systems.isEmpty;

  Iterable<NodePlanet> get planets =>
      systems.expand((system) => system.planets);

  /// The planet with [id], and its system.
  ({CountrySystem system, NodePlanet planet})? planetOf(String id) {
    for (final system in systems) {
      for (final planet in system.planets) {
        if (planet.id == id) return (system: system, planet: planet);
      }
    }
    return null;
  }

  CountrySystem? systemOf(String id) {
    for (final system in systems) {
      if (system.id == id) return system;
    }
    return null;
  }

  /// The node the proxy is connected through, if it is in the scene.
  ({CountrySystem system, NodePlanet planet})? get current {
    for (final system in systems) {
      for (final planet in system.planets) {
        if (planet.node.current) return (system: system, planet: planet);
      }
    }
    return null;
  }

  /// How far the farthest orbit reaches from the home star.
  double get reach {
    var reach = 2.0;
    for (final system in systems) {
      reach = math.max(reach, system.position.length + system.extent);
    }
    return reach;
  }

  /// The middle of everything drawn, home star included: what the camera
  /// looks at so a lopsided catalogue still fills the view.
  Vec3 get center {
    var minX = 0.0, maxX = 0.0, minZ = 0.0, maxZ = 0.0;
    for (final system in systems) {
      final p = system.position, e = system.extent;
      minX = math.min(minX, p.x - e);
      maxX = math.max(maxX, p.x + e);
      minZ = math.min(minZ, p.z - e);
      maxZ = math.max(maxZ, p.z + e);
    }
    return Vec3((minX + maxX) / 2, 0, (minZ + maxZ) / 2);
  }

  /// How far the farthest orbit reaches from [center].
  double get radius {
    final c = center;
    var radius = 2.0;
    for (final system in systems) {
      radius = math.max(radius, (system.position - c).length + system.extent);
    }
    return math.max(radius, c.length + 0.5);
  }
}

/// Distance from the centre to the North Pole's ring of the map: the home
/// star keeps this much room for itself.
const double _homeClearance = 2.4;

/// World units from the North Pole to the South Pole.
const double _poleToPole = 11.0;

/// Room kept between two systems' outermost orbits.
const double _gap = 0.5;

/// The radius of the circle of latitude [lat] on the disk.
double latitudeRadius(double lat) =>
    _homeClearance + (90 - lat) / 180 * _poleToPole;

/// Where [info] sits on the disk: an azimuthal projection centred on the
/// North Pole, so neighbours on Earth are neighbours here, east runs
/// counter-clockwise seen from above, and the southern countries are outside.
Vec3 projectCountry(CountryInfo info) {
  final r = latitudeRadius(info.lat);
  final theta = info.lon * math.pi / 180;
  return Vec3(math.sin(theta) * r, 0, math.cos(theta) * r);
}

/// Up to this many bodies share the innermost ring; each ring out holds
/// four more.
const int _firstRing = 6;

List<NodePlanet> _planetsOf(String code, List<GalaxyNode> nodes) {
  final sorted = [...nodes]..sort((a, b) => a.id.compareTo(b.id));
  final planets = <NodePlanet>[];
  var ring = 0;
  var start = 0;
  while (start < sorted.length) {
    final capacity = _firstRing + ring * 4;
    final group = sorted.sublist(
      start,
      math.min(start + capacity, sorted.length),
    );
    final radius = 0.6 + ring * 0.3;
    // Kepler: outer rings turn slower; the innermost takes about a minute.
    final period = 64 * math.pow(radius / 0.6, 1.5).toDouble();
    final seed = stableHash('$code/$ring');
    for (var i = 0; i < group.length; i++) {
      final node = group[i];
      planets.add(
        NodePlanet(
          node: node,
          ring: ring,
          radius: radius,
          phase: unitOf(seed) * math.pi * 2 + i * math.pi * 2 / group.length,
          period: period,
          size: node.current ? 0.085 : 0.066,
          tiltAxis: unitOf(seed >> 3) * math.pi * 2,
          tilt: (unitOf(seed >> 7) - 0.5) * 0.3,
        ),
      );
    }
    start += capacity;
    ring++;
  }
  return planets;
}

/// Lay [nodes] out as a scene.
///
/// Positions depend only on which countries are present and how many nodes
/// each has, so testing a node or connecting to one never moves a system.
GalaxyScene buildGalaxyScene(List<GalaxyNode> nodes, {bool connected = false}) {
  final byCountry = <String, List<GalaxyNode>>{};
  for (final node in nodes) {
    byCountry.putIfAbsent(node.country, () => []).add(node);
  }
  if (byCountry.isEmpty) {
    return GalaxyScene(systems: const [], connected: connected);
  }

  final codes = byCountry.keys.toList()..sort();
  final planets = {
    for (final code in codes) code: _planetsOf(code, byCountry[code]!),
  };
  final extents = {
    for (final code in codes)
      code: planets[code]!.map((p) => p.radius).fold(0.4, math.max) + 0.22,
  };

  final seeds = <String, Vec3>{};
  for (final code in codes) {
    if (code.isEmpty) continue;
    final info = countryInfo(code);
    if (info != null) {
      seeds[code] = projectCountry(info);
    } else {
      // A code the atlas does not know still gets a stable place on the
      // southern rim rather than none.
      final angle = unitOf(stableHash(code)) * math.pi * 2;
      final r = _homeClearance + _poleToPole * 0.8;
      seeds[code] = Vec3(math.sin(angle) * r, 0, math.cos(angle) * r);
    }
  }
  if (byCountry.containsKey('')) {
    seeds[''] = _unknownSeed(seeds.values.toList());
  }

  final positions = relaxGalaxyPositions(codes, seeds, extents);
  return GalaxyScene(
    connected: connected,
    systems: [
      for (final code in codes)
        CountrySystem(
          code: code,
          position: positions[code]!,
          planets: planets[code]!,
          extent: extents[code]!,
        ),
    ],
  );
}

/// Unlocated nodes gather on the far side of the known ones, outside them,
/// so they never hide a country.
Vec3 _unknownSeed(List<Vec3> known) {
  if (known.isEmpty) {
    // Alone, it sits in front of home, towards the default camera.
    return Vec3(math.sin(1.92) * 4.2, 0, math.cos(1.92) * 4.2);
  }
  var sum = Vec3.zero;
  var outer = 0.0;
  for (final p in known) {
    sum = sum + p.unit;
    outer = math.max(outer, p.length);
  }
  final angle = sum.length < 1e-6 ? 0.0 : math.atan2(sum.x, sum.z) + math.pi;
  final r = outer + 1.6;
  return Vec3(math.sin(angle) * r, 0, math.cos(angle) * r);
}

/// Push overlapping systems apart while each stays close to where its
/// country is, and keep them all clear of the home star.
Map<String, Vec3> relaxGalaxyPositions(
  List<String> codes,
  Map<String, Vec3> seeds,
  Map<String, double> extents, {
  bool useNative = true,
  NativeGalaxyLayout? nativeLayout,
}) {
  final native = useNative
      ? (nativeLayout ?? _nativeLayout).place(codes, [
          for (final c in codes) ...[seeds[c]!.x, seeds[c]!.z, extents[c]!],
        ])
      : null;
  if (native != null) {
    return {
      for (var i = 0; i < codes.length; i++)
        codes[i]: Vec3(native[i * 2], 0, native[i * 2 + 1]),
    };
  }
  final xs = {for (final c in codes) c: seeds[c]!.x};
  final zs = {for (final c in codes) c: seeds[c]!.z};
  for (var iteration = 0; iteration < 240; iteration++) {
    for (final c in codes) {
      // A weak spring back to the country's own place.
      xs[c] = xs[c]! + (seeds[c]!.x - xs[c]!) * 0.015;
      zs[c] = zs[c]! + (seeds[c]!.z - zs[c]!) * 0.015;
      final r = math.sqrt(xs[c]! * xs[c]! + zs[c]! * zs[c]!);
      final minimum = extents[c]! + 1.5;
      if (r < minimum) {
        if (r < 1e-6) {
          xs[c] = minimum;
          zs[c] = 0;
        } else {
          xs[c] = xs[c]! * minimum / r;
          zs[c] = zs[c]! * minimum / r;
        }
      }
    }
    var moved = false;
    for (var i = 0; i < codes.length; i++) {
      for (var j = i + 1; j < codes.length; j++) {
        final a = codes[i], b = codes[j];
        var dx = xs[b]! - xs[a]!;
        var dz = zs[b]! - zs[a]!;
        var d = math.sqrt(dx * dx + dz * dz);
        final need = extents[a]! + extents[b]! + _gap;
        if (d >= need) continue;
        if (d < 1e-6) {
          // Exactly coincident: separate along a direction fixed by the
          // pair, so the result never depends on iteration order.
          final angle = unitOf(stableHash('$a|$b')) * math.pi * 2;
          dx = math.cos(angle);
          dz = math.sin(angle);
          d = 1;
        } else {
          dx /= d;
          dz /= d;
        }
        final push = (need - d) / 2;
        xs[a] = xs[a]! - dx * push;
        zs[a] = zs[a]! - dz * push;
        xs[b] = xs[b]! + dx * push;
        zs[b] = zs[b]! + dz * push;
        moved = true;
      }
    }
    if (!moved) break;
  }
  return {for (final c in codes) c: Vec3(xs[c]!, 0, zs[c]!)};
}

/// The scene with only the planets [keep] accepts; systems left without any
/// disappear, the rest keep their places.
GalaxyScene filterGalaxyScene(
  GalaxyScene scene,
  bool Function(GalaxyNode node) keep,
) {
  return GalaxyScene(
    connected: scene.connected,
    systems: [
      for (final system in scene.systems)
        if (system.planets.where((p) => keep(p.node)).toList() case final kept
            when kept.isNotEmpty)
          system.withPlanets(kept),
    ],
  );
}
