/// Where the galaxy is seen from: a camera orbiting a target on the disk, in
/// true perspective, easing smoothly between framings.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'galaxy_model.dart';

/// One projected point.
typedef Projected = ({Offset point, double scale, double depth});

/// The view of one frame: world points to screen points.
class Projection {
  Projection({
    required this.eye,
    required Vec3 target,
    required this.center,
    required this.focal,
  }) : forward = (target - eye).unit,
       right = (target - eye).unit.cross(const Vec3(0, 1, 0)).unit,
       up = (target - eye).unit
           .cross(const Vec3(0, 1, 0))
           .unit
           .cross((target - eye).unit);

  final Vec3 eye;
  final Vec3 forward;
  final Vec3 right;
  final Vec3 up;
  final Offset center;

  /// Focal length in pixels.
  final double focal;

  /// [p] on screen, or null behind the camera.
  Projected? at(Vec3 p) {
    final v = p - eye;
    final depth = v.dot(forward);
    if (depth < 0.2) return null;
    final s = focal / depth;
    return (
      point: Offset(center.dx + v.dot(right) * s, center.dy - v.dot(up) * s),
      scale: s,
      depth: depth,
    );
  }
}

/// The camera, with goals it eases towards.
class GalaxyCamera {
  /// Turn of the disk around its axis. The default faces East Asia, where
  /// most of this app's users are, towards the viewer.
  double yaw = defaultYaw;

  /// Elevation above the disk plane, in radians.
  double tilt = _defaultTilt;

  /// Distance from the target.
  double distance = 24;

  Vec3 target = Vec3.zero;

  double goalTilt = _defaultTilt;
  double goalDistance = 24;
  Vec3 goalTarget = Vec3.zero;

  /// Yaw speed left over from a fling, decaying.
  double spin = 0;

  /// The distance that frames every system.
  double fitDistance = 24;

  /// What the whole-galaxy framing looks at.
  Vec3 home = Vec3.zero;

  /// The resting elevation; higher on a portrait screen so the disk fills
  /// its height.
  double restTilt = _defaultTilt;

  static const double defaultYaw = 1.92;
  static const double _defaultTilt = 0.8;

  /// One turn every eight minutes.
  static const double driftSpeed = math.pi * 2 / 480;

  /// Fit [radius] world units of disk on a canvas of [size]. The panel and
  /// toolbar cover part of the canvas, so the disk is framed a little inside.
  void fit(double radius, Size size) {
    if (size.isEmpty) return;
    restTilt = size.height > size.width * 1.2 ? 1.0 : _defaultTilt;
    final focal = _focal(size);
    final across = radius * focal / (size.width * 0.5);
    final deep = radius * math.sin(restTilt) * focal / (size.height * 0.38);
    fitDistance = math.max(8.0, math.max(across, deep) + radius * 0.25);
  }

  /// Ease back to the whole galaxy.
  void overview() {
    goalTarget = home;
    goalDistance = fitDistance;
    goalTilt = restTilt;
  }

  /// Ease to frame [point] from [closeness] away.
  void focus(Vec3 point, double closeness) {
    goalTarget = point;
    goalDistance = closeness;
  }

  /// Orbit by a drag of [dx], [dy] pixels.
  void drag(double dx, double dy) {
    yaw -= dx * 0.006;
    goalTilt = (goalTilt + dy * 0.004).clamp(0.18, 1.35);
    tilt = goalTilt;
  }

  /// Zoom by [factor] (above one: closer).
  void zoom(double factor) {
    goalDistance = (goalDistance / factor).clamp(2.4, fitDistance * 1.8);
  }

  /// Advance by [dt] seconds; [drifting] turns the disk slowly.
  void step(double dt, {required bool drifting}) {
    final ease = 1 - math.exp(-dt * 3.2);
    tilt += (goalTilt - tilt) * ease;
    distance += (goalDistance - distance) * ease;
    target = target.lerp(goalTarget, ease);
    yaw += spin * dt;
    spin *= math.exp(-dt * 2.4);
    if (spin.abs() < 0.002) spin = 0;
    if (drifting) yaw += driftSpeed * dt;
  }

  /// Whether it has arrived and nothing turns it (drift aside).
  bool get settled =>
      spin == 0 &&
      (goalTilt - tilt).abs() < 1e-4 &&
      (goalDistance - distance).abs() < 1e-3 &&
      (goalTarget - target).length < 1e-3;

  /// A long lens: depth still reads, but the far side of the disk is not
  /// shrunk so much that its systems become specks.
  static double _focal(Size size) => size.shortestSide * 1.4;

  /// This frame's projection for a canvas of [size].
  Projection project(Size size) {
    final eye =
        target +
        Vec3(
              math.cos(tilt) * math.sin(yaw),
              math.sin(tilt),
              math.cos(tilt) * math.cos(yaw),
            ) *
            distance;
    return Projection(
      eye: eye,
      target: target,
      center: Offset(size.width / 2, size.height * 0.54),
      focal: _focal(size),
    );
  }
}
