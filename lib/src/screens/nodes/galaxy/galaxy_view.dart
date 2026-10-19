/// What the galaxy painter reads each frame, owned by the page: the scene,
/// the camera, the clock, what is selected or hovered, and the motion of
/// nodes that appeared, changed state or moved to another country.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/node_health.dart';
import 'galaxy_camera.dart';
import 'galaxy_model.dart';

/// A body drawn this frame, for hit testing.
class Hit {
  const Hit(this.id, this.center, this.radius, this.depth);

  /// [homeId], a system id or a node id.
  final String id;
  final Offset center;
  final double radius;
  final double depth;
}

/// A node that left the scene, fading where it was.
class Ghost {
  const Ghost(this.position, this.size, this.since);

  final Vec3 position;
  final double size;
  final double since;
}

/// A node on its way from one country to another, usually out of the
/// unlocated cluster after a test found where its traffic leaves from.
class Migration {
  const Migration(this.from, this.since);

  /// World position it left from.
  final Vec3 from;
  final double since;

  static const double duration = 1.8;
}

/// The page-owned state of the galaxy.
class GalaxyView extends ChangeNotifier {
  GalaxyScene scene = GalaxyScene.empty;

  final GalaxyCamera camera = GalaxyCamera();

  /// Scene time in seconds.
  double time = 0;

  /// Reduced motion: every body rests where its orbit starts.
  bool still = false;

  double motionTime = 0;
  double get orbitTime => still ? 0 : motionTime;

  String? selected;
  String? hovered;

  /// The body with keyboard focus.
  String? focused;

  /// When each node appeared (it spirals out of its star).
  final Map<String, double> appeared = {};

  /// When each node's state last changed (a ripple crosses its orbit).
  final Map<String, double> rippled = {};

  /// Nodes travelling between countries.
  final Map<String, Migration> migrations = {};

  final List<Ghost> ghosts = [];

  /// Bodies drawn in the last frame.
  List<Hit> hits = const [];

  /// Whether anything is animating on its own: entrances, ripples, flights,
  /// fading ghosts or a probe in flight.
  bool get busy =>
      !still &&
      (appeared.isNotEmpty ||
          rippled.isNotEmpty ||
          migrations.isNotEmpty ||
          ghosts.isNotEmpty ||
          scene.planets.any((p) => p.node.health == NodeHealth.testing));

  /// Expire transitions even for nodes behind the camera or removed by a
  /// filter. Their lifetime must not depend on the painter visiting them.
  void expireTransitions() {
    appeared.removeWhere((_, since) => still || time - since >= 1.6);
    rippled.removeWhere((_, since) => still || time - since >= 1.4);
    migrations.removeWhere(
      (_, flight) => still || time - flight.since >= Migration.duration,
    );
    ghosts.removeWhere((ghost) => still || time - ghost.since >= 1);
  }

  void tick() => notifyListeners();

  /// Take [next] as the scene, noting what appeared, changed, moved or left.
  void update(GalaxyScene next, {required bool first}) {
    final animate = !first && !still;
    final before =
        <String, ({NodeHealth health, Vec3 at, String system, double size})>{};
    for (final system in scene.systems) {
      for (final planet in system.planets) {
        before[planet.id] = (
          health: planet.node.health,
          at: system.position + planet.offsetAt(orbitTime),
          system: system.id,
          size: planet.size,
        );
      }
    }
    final now = <String>{};
    for (final system in next.systems) {
      for (final planet in system.planets) {
        now.add(planet.id);
        final old = before[planet.id];
        if (!animate) continue;
        if (old == null) {
          appeared[planet.id] = time;
        } else if (old.system != system.id) {
          migrations[planet.id] = Migration(old.at, time);
        } else if (old.health != planet.node.health) {
          rippled[planet.id] = time;
        }
      }
    }
    if (animate) {
      for (final entry in before.entries) {
        if (!now.contains(entry.key)) {
          ghosts.add(Ghost(entry.value.at, entry.value.size, time));
        }
      }
    }
    scene = next;
  }

  /// The world position of body [id] as it is drawn now.
  Vec3? positionOf(String id) {
    if (id == homeId) return Vec3.zero;
    for (final system in scene.systems) {
      if (system.id == id) return system.position;
      for (final planet in system.planets) {
        if (planet.id == id) {
          return system.position + planet.offsetAt(orbitTime);
        }
      }
    }
    return null;
  }

  /// The front-most body drawn under [point]; else the nearest one within
  /// reach, so a small planet still takes a fingertip.
  Hit? hitAt(Offset point) {
    Hit? drawn;
    Hit? near;
    var nearest = double.infinity;
    for (final hit in hits) {
      final distance = (hit.center - point).distance;
      if (distance <= hit.radius &&
          (drawn == null || hit.depth < drawn.depth)) {
        drawn = hit;
      }
      final reach = math.max(16.0, hit.radius + 8);
      if (distance <= reach && distance < nearest) {
        near = hit;
        nearest = distance;
      }
    }
    return drawn ?? near;
  }
}
