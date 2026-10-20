/// Paints one frame of the galaxy: sky, the circles of latitude, the home
/// star, country systems far to near with their orbits split around each
/// star, the connection to the current node as an arc of light, and labels
/// that keep out of each other's way.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../models/node_health.dart';
import '../../../theme/app_theme.dart';
import 'flag_atlas.dart';
import 'galaxy_backdrop.dart';
import 'galaxy_camera.dart';
import 'galaxy_geometry.dart';
import 'galaxy_model.dart';
import 'galaxy_view.dart';
import 'planet_atlas.dart';

/// The colours of one theme.
class GalaxyPalette {
  const GalaxyPalette({
    required this.scheme,
    required this.status,
    required this.ratio,
    required this.text,
  });

  final ColorScheme scheme;
  final StatusColors status;

  /// Device pixel ratio.
  final double ratio;

  /// The app's text style, for labels.
  final TextStyle text;

  bool get dark => scheme.brightness == Brightness.dark;

  /// Ink for orbits, guides and labels.
  Color get ink => dark ? Colors.white : const Color(0xFF23232A);

  /// The one signal colour: the device in the user's hand, and its link to
  /// the node it is connected through.
  Color get signal => scheme.primary;

  Color health(NodeHealth health) => status.health(health, scheme);

  bool same(GalaxyPalette o) =>
      o.scheme == scheme &&
      o.ratio == ratio &&
      o.status.good == status.good &&
      o.status.fair == status.fair;
}

/// The words the galaxy writes on the sky.
class GalaxyText {
  const GalaxyText({
    required this.home,
    required this.unlocated,
    required this.countryName,
    required this.countryStats,
  });

  /// The home star.
  final String home;

  /// The cluster of nodes whose location is unknown.
  final String unlocated;
  final String Function(String code) countryName;

  /// "15 nodes · 9 available".
  final String Function(int total, int available) countryStats;
}

/// Laid-out labels, reused across frames.
class LabelCache {
  final Map<String, TextPainter> _painters = {};
  final Set<String> _used = {};

  void beginFrame() => _used.clear();

  void endFrame() {
    _painters.removeWhere((key, painter) {
      if (_used.contains(key)) return false;
      painter.dispose();
      return true;
    });
  }

  TextPainter of(String key, InlineSpan Function() span) {
    _used.add(key);
    final cached = _painters[key];
    if (cached != null) return cached;
    return _painters[key] = TextPainter(
      text: span(),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: 240);
  }

  void dispose() {
    for (final painter in _painters.values) {
      painter.dispose();
    }
    _painters.clear();
    _used.clear();
  }
}

double _easeOut(double t) => 1 - math.pow(1 - t.clamp(0, 1), 3).toDouble();

double _easeInOut(double t) {
  final x = t.clamp(0.0, 1.0);
  return x < 0.5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3) / 2;
}

/// [p] turned by [angle] around the disk's axis.
Vec3 _turned(Vec3 p, double angle) {
  final c = math.cos(angle), s = math.sin(angle);
  return Vec3(p.x * c - p.z * s, p.y, p.x * s + p.z * c);
}

/// The painter. Repaints whenever [view] ticks.
class GalaxyPainter extends CustomPainter {
  GalaxyPainter({
    required this.view,
    required this.palette,
    required this.text,
    required this.labels,
    required this.starfield,
    required this.backdrop,
    required this.planets,
    required this.geometry,
    required this.onBackdrop,
  }) : super(repaint: view);

  final GalaxyView view;
  final GalaxyPalette palette;
  final GalaxyText text;
  final LabelCache labels;
  final Starfield starfield;
  final BackdropCache backdrop;
  final PlanetAtlas planets;
  final GalaxyGeometry geometry;

  /// Called when the backdrop image arrives.
  final VoidCallback onBackdrop;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    labels.beginFrame();
    if (view.still) {
      view.appeared.clear();
      view.rippled.clear();
      view.migrations.clear();
      view.ghosts.clear();
    }
    final camera = view.camera;
    final sky = backdrop.of(size, palette.scheme, palette.ratio, onBackdrop);
    if (sky == null) {
      paintGround(canvas, size, palette.scheme);
    } else {
      sky.paint(canvas);
    }
    starfield.paint(
      canvas,
      size,
      camera.yaw,
      camera.tilt,
      view.time,
      dark: palette.dark,
      still: view.still,
    );
    final projection = camera.project(size);
    geometry.project(view.scene, projection, size);
    final frame = _Frame(this, canvas, projection, size);
    frame.plane();
    final ordered = [
      for (final system in view.scene.systems)
        if (projection.at(system.position) case final core?) (system, core),
    ]..sort((a, b) => b.$2.depth.compareTo(a.$2.depth));
    final home = projection.at(Vec3.zero);
    var homeDrawn = false;
    for (final (system, core) in ordered) {
      // The home star takes its turn in depth order like any other.
      if (!homeDrawn && home != null && core.depth < home.depth) {
        frame.home(home);
        homeDrawn = true;
      }
      frame.system(system, core);
    }
    if (!homeDrawn && home != null) frame.home(home);
    frame.link();
    frame.ghosts();
    frame.labels();
    view.hits = frame.hits;
    labels.endFrame();
    canvas.restore();
  }

  @override
  bool shouldRepaint(GalaxyPainter old) =>
      old.view != view || !old.palette.same(palette) || old.text != text;
}

/// A label waiting for a place.
class _Label {
  _Label(this.id, this.anchor, this.gap, this.rank, this.painter);

  final String id;
  final Offset anchor;

  /// Distance below the body's centre.
  final double gap;
  final double rank;
  final TextPainter painter;
}

/// One frame's drawing state.
class _Frame {
  _Frame(this.painter, this.canvas, this.projection, this.size);

  final GalaxyPainter painter;
  final Canvas canvas;
  final Projection projection;
  final Size size;
  final List<Hit> hits = [];
  final List<_Label> pending = [];
  final List<Rect> obstacles = [];
  final _sprites = _SpriteBatch();

  GalaxyView get view => painter.view;
  GalaxyPalette get palette => painter.palette;
  bool get dark => palette.dark;

  /// A reusable texture avoids re-evaluating a large radial shader per halo.
  void _glow(Offset center, double radius, Color color) {
    if (!_visible(center, radius * 2.5)) return;
    final image = painter.planets.glowFor(color, painter.onBackdrop);
    if (image != null) _sprite(image, center, radius, color.a);
  }

  /// Whether [id] (of [system]) stays bright while something is selected.
  bool _lit(String id, CountrySystem system) {
    final selected = view.selected;
    if (selected == null || selected == homeId) return true;
    if (selected == id || selected == system.id) return true;
    return id == system.id && system.planets.any((p) => p.id == selected);
  }

  /// Fainter with distance, so depth reads without blur.
  double _fade(double depth) {
    final reference = view.camera.distance;
    return (1.25 - (depth - reference) / (reference * 1.6)).clamp(0.4, 1.0);
  }

  /// The disk's plane: a soft glow, circles of latitude and a few meridians,
  /// so the map reads as the Earth seen from above the North Pole.
  void plane() {
    final reach = math.max(view.scene.reach, latitudeRadius(-30));
    final rim = <Offset>[];
    for (var i = 0; i < 48; i++) {
      final a = i / 48 * math.pi * 2;
      final p = projection.at(
        Vec3(math.cos(a) * reach, 0, math.sin(a) * reach),
      );
      if (p != null) rim.add(p.point);
    }
    if (rim.length > 8) {
      var bounds = Rect.fromPoints(rim.first, rim.first);
      for (final point in rim) {
        bounds = bounds.expandToInclude(Rect.fromPoints(point, point));
      }
      // A radial falloff needs one draw, unlike a canvas-sized blur pass.
      canvas.drawOval(
        bounds,
        Paint()
          ..shader = RadialGradient(
            colors: [
              palette.signal.withValues(alpha: dark ? 0.05 : 0.035),
              palette.signal.withValues(alpha: 0),
            ],
          ).createShader(bounds),
      );
    }
    const latitudes = [60.0, 30.0, 0.0, -30.0, -60.0];
    for (var index = 0; index < latitudes.length; index++) {
      final lat = latitudes[index];
      final r = latitudeRadius(lat);
      if (r > reach * 1.08) continue;
      final equator = lat == 0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = equator ? 1.0 : 0.8
        ..color = palette.ink.withValues(
          alpha:
              (equator ? (dark ? 0.12 : 0.13) : (dark ? 0.06 : 0.07)) *
              (1 - r / (reach * 1.3)),
        );
      painter.geometry.guides[index].draw(canvas, paint, dashed: equator);
    }
    final meridian = Paint()
      ..strokeWidth = 0.7
      ..color = palette.ink.withValues(alpha: dark ? 0.045 : 0.05);
    painter.geometry.guides[5].draw(canvas, meridian);
  }

  bool _visible(Offset point, double margin) =>
      (Offset.zero & size).inflate(margin).contains(point);

  /// The device in the user's hand, at the centre.
  void home(Projected core) {
    if (!_visible(core.point, 400)) return;
    final breath = view.still ? 1.0 : 1 + 0.05 * math.sin(view.time * 1.1);
    final radius = (0.26 * core.scale).clamp(5.0, 24.0) * breath;
    final c = core.point;
    final color = palette.signal;
    final opacity = view.selected == null || view.selected == homeId
        ? 1.0
        : 0.55;
    for (final (scale, alpha) in [(6.0, 0.07), (3.2, 0.16), (1.8, 0.3)]) {
      _glow(
        c,
        radius * scale,
        color.withValues(alpha: alpha * opacity * (dark ? 1 : 0.7)),
      );
    }
    _sphere(c, radius, color, opacity, glow: 0);
    _focusRings(homeId, c, radius);
    hits.add(Hit(homeId, c, radius * 1.5, core.depth));
    obstacles.add(Rect.fromCircle(center: c, radius: radius));
    final emphasis = _emphasized(homeId);
    pending.add(
      _Label(
        homeId,
        c,
        radius + 8,
        emphasis ? 4 : 2.8,
        _text('home|$emphasis', () => _strongSpan(painter.text.home)),
      ),
    );
  }

  void system(CountrySystem system, Projected core) {
    final lit = _lit(system.id, system);
    final base = (lit ? 1.0 : 0.28) * _fade(core.depth);
    final orbit = painter.geometry.orbits[system.id]!;
    final placed = [
      for (final planet in system.planets)
        if (_place(system, planet) case final p?) (planet, p.$1, p.$2),
    ];
    _strokeOrbit(orbit.back, base * 0.55);
    for (final (planet, projected, appear) in placed) {
      if (projected.depth > core.depth) {
        _planet(system, planet, projected, appear, base);
      }
    }
    _sprites.draw(canvas);
    _star(system, core, base);
    _strokeOrbit(orbit.front, base);
    for (final (planet, projected, appear) in placed) {
      if (projected.depth <= core.depth) {
        _planet(system, planet, projected, appear, base);
      }
    }
    _sprites.draw(canvas);
  }

  void _strokeOrbit(GalaxyLines lines, double opacity) {
    if (opacity <= 0) return;
    lines.draw(
      canvas,
      Paint()
        ..strokeWidth = dark ? 0.9 : 0.8
        ..color = palette.ink.withValues(alpha: (dark ? 0.15 : 0.2) * opacity),
    );
  }

  /// Where [planet] is drawn now, and how far it has come out of its star.
  (Projected, double)? _place(CountrySystem system, NodePlanet planet) {
    final since = view.appeared[planet.id];
    final appear = since == null ? 1.0 : _easeOut((view.time - since) / 1.6);
    if (since != null && appear >= 1) view.appeared.remove(planet.id);
    final orbit = planet.offsetAt(view.orbitTime);
    var world =
        system.position +
        (appear >= 1
            ? orbit
            : _turned(orbit, (1 - appear) * math.pi) * appear +
                  Vec3(0, 0.25 * (1 - appear), 0));
    final migration = view.migrations[planet.id];
    if (migration != null) {
      final t = (view.time - migration.since) / Migration.duration;
      if (t >= 1) {
        view.migrations.remove(planet.id);
      } else {
        // A comet's flight: up out of the plane and down into its new orbit.
        final e = _easeInOut(t);
        final lift =
            math.sin(t * math.pi) *
            (0.6 + (world - migration.from).length * 0.18);
        world = migration.from.lerp(world, e) + Vec3(0, lift, 0);
      }
    }
    final projected = projection.at(world);
    return projected == null || !_visible(projected.point, 140)
        ? null
        : (projected, appear);
  }

  /// A country's star: its flag as a lit sphere, and around it a ring
  /// divided by how its nodes answered.
  void _star(CountrySystem system, Projected core, double opacity) {
    if (!_visible(core.point, 330)) return;
    final breath = view.still
        ? 1.0
        : 1 + 0.03 * math.sin(view.time * 0.8 + system.position.x);
    final radius =
        ((system.unknown ? 0.17 : 0.22) * core.scale).clamp(5.0, 30.0) * breath;
    final c = core.point;
    final available = system.available;
    final glow = system.unknown
        ? palette.scheme.outline
        : available > 0
        ? palette.status.good
        : palette.scheme.outline;
    if (dark) {
      for (final (scale, alpha) in [(4.4, 0.06), (2.4, 0.14)]) {
        _glow(
          c,
          radius * scale,
          Color.lerp(
            Colors.white,
            glow,
            0.35,
          )!.withValues(alpha: alpha * opacity),
        );
      }
    } else {
      _glow(c, radius * 2.2, glow.withValues(alpha: 0.12 * opacity));
    }
    final flag = system.unknown
        ? null
        : FlagAtlas.instance.imageFor(system.code);
    final sprite = flag == null
        ? null
        : painter.planets.flagFor(system.code, flag, dark, painter.onBackdrop);
    if (sprite == null) {
      _sphere(
        c,
        radius,
        system.unknown
            ? palette.scheme.outline
            : Color.lerp(palette.scheme.surfaceContainerHighest, glow, 0.3)!,
        opacity,
        glow: 0,
      );
      final mark = system.unknown ? '?' : system.code;
      final glyph = _text(
        'glyph|$mark|${radius.round()}',
        () => TextSpan(
          text: mark,
          style: palette.text.copyWith(
            fontSize: radius * (system.unknown ? 1.1 : 0.62),
            fontWeight: FontWeight.w700,
            color: Colors.white.withValues(alpha: 0.92),
            height: 1,
          ),
        ),
      );
      canvas.saveLayer(
        Rect.fromCircle(center: c, radius: radius),
        Paint()..color = Colors.white.withValues(alpha: opacity),
      );
      glyph.paint(canvas, c - Offset(glyph.width / 2, glyph.height / 2));
      canvas.restore();
    } else {
      _sprite(sprite, c, radius, opacity);
    }
    _statusRing(system, c, radius * 1.42, opacity);
    _focusRings(system.id, c, radius * 1.42);
    hits.add(Hit(system.id, c, radius * 1.5, core.depth));
    obstacles.add(Rect.fromCircle(center: c, radius: radius * 1.42));
    final emphasis = _emphasized(system.id);
    final name = system.unknown
        ? painter.text.unlocated
        : painter.text.countryName(system.code);
    final stats = painter.text.countryStats(system.planets.length, available);
    pending.add(
      _Label(
        system.id,
        c,
        radius * 1.42 + 7,
        emphasis ? 4 : 2.6,
        _text(
          'star|$name|$stats|$emphasis',
          () => TextSpan(
            children: [
              _strongSpan(name),
              TextSpan(
                text: '\n$stats',
                style: _baseStyle().copyWith(
                  fontSize: 10.5,
                  color: palette.ink.withValues(alpha: dark ? 0.6 : 0.58),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _statusRing(
    CountrySystem system,
    Offset c,
    double radius,
    double opacity,
  ) {
    final total = system.planets.length;
    if (total == 0) return;
    final counts = system.counts;
    final rect = Rect.fromCircle(center: c, radius: radius);
    final stroke = (radius * 0.13).clamp(1.6, 3.6);
    canvas.drawCircle(
      c,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = palette.ink.withValues(alpha: (dark ? 0.1 : 0.08) * opacity),
    );
    final gap = total > 1 ? math.min(0.08, math.pi / total * 0.4) : 0.0;
    var start = -math.pi / 2;
    for (final health in NodeHealth.displayOrder) {
      final count = counts[health] ?? 0;
      if (count == 0) continue;
      final sweep = math.pi * 2 * count / total;
      canvas.drawArc(
        rect,
        start + gap / 2,
        math.max(0.02, sweep - gap),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = palette.health(health).withValues(alpha: 0.95 * opacity),
      );
      start += sweep;
    }
  }

  void _planet(
    CountrySystem system,
    NodePlanet planet,
    Projected projected,
    double appear,
    double base,
  ) {
    final node = planet.node;
    final lit = _lit(planet.id, system);
    final opacity = (lit ? 1.0 : 0.28) * _fade(projected.depth) * appear;
    final radius =
        (planet.size * projected.scale).clamp(2.4, 14.0) * (0.4 + 0.6 * appear);
    final c = projected.point;
    final color = palette.health(node.health);
    final rippled = view.rippled[planet.id];
    if (rippled != null) {
      final t = (view.time - rippled) / 1.4;
      if (t >= 1) {
        view.rippled.remove(planet.id);
      } else {
        canvas.drawCircle(
          c,
          radius * (1.2 + t * 3.4),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = color.withValues(alpha: (1 - t) * 0.7 * opacity),
        );
      }
    }
    if (node.current) {
      final live = view.scene.connected;
      final pulse = view.still || !live
          ? 0.5
          : (math.sin(view.time * 2.2) + 1) / 2;
      _glow(
        c,
        radius * (2.0 + pulse * 0.5),
        palette.signal.withValues(alpha: (live ? 0.18 : 0.08) * opacity),
      );
      canvas.drawCircle(
        c,
        radius * 1.75,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = palette.signal.withValues(alpha: 0.9 * opacity),
      );
    }
    _sphere(c, radius, color, opacity, batch: true);
    if (node.health == NodeHealth.testing) {
      // Still, and turned per node so a country under test does not show a
      // row of identical marks.
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: radius * 1.9),
        unitOf(stableHash(planet.id)) * math.pi * 2,
        math.pi * 1.2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.85 * opacity),
      );
    }
    _focusRings(planet.id, c, radius * (node.current ? 1.75 : 1.0));
    hits.add(Hit(planet.id, c, math.max(radius, 5), projected.depth));
    if (view.migrations.containsKey(planet.id) || appear < 1) return;
    final emphasis = _emphasized(planet.id);
    if (!emphasis && !node.current && radius < 3.6) return;
    if (!lit && !emphasis) return;
    final latency = node.health.isAvailable && node.latencyMs != null
        ? ' · ${node.latencyMs}ms'
        : '';
    final address = emphasis ? node.node.addr : node.host;
    pending.add(
      _Label(
        planet.id,
        c,
        radius * (node.current ? 1.75 : 1) + 4,
        emphasis ? 4 : (node.current ? 2.4 : 1 + radius / 100),
        _text(
          'node|$address$latency|$emphasis|${node.current}',
          () => TextSpan(
            text: '$address$latency',
            style:
                (emphasis || node.current
                        ? _baseStyle().copyWith(
                            fontWeight: FontWeight.w600,
                            color: palette.ink.withValues(alpha: 0.9),
                          )
                        : _baseStyle())
                    .copyWith(
                      fontSize: 10.5,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
          ),
        ),
      ),
    );
  }

  void _sphere(
    Offset c,
    double radius,
    Color color,
    double opacity, {
    double glow = 0.9,
    bool batch = false,
  }) {
    final image = painter.planets.imageFor(
      color,
      dark,
      painter.onBackdrop,
      glow: glow,
    );
    if (image == null) {
      // A cheap placeholder while the full-quality texture is rasterized once.
      canvas.drawCircle(
        c,
        radius,
        Paint()..color = color.withValues(alpha: opacity),
      );
    } else {
      if (batch) {
        _sprites.add(image, c, radius, opacity);
      } else {
        _sprite(image, c, radius, opacity);
      }
    }
  }

  void _sprite(ui.Image image, Offset c, double radius, double opacity) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCircle(
        center: c,
        radius: radius * PlanetAtlas.edge / (2 * PlanetAtlas.radius),
      ),
      Paint()
        ..filterQuality = FilterQuality.low
        ..color = Colors.white.withValues(alpha: opacity),
    );
  }

  bool _emphasized(String id) =>
      view.selected == id || view.hovered == id || view.focused == id;

  void _focusRings(String id, Offset c, double radius) {
    final pulse = view.still ? 0.0 : (math.sin(view.time * 3) + 1) / 2;
    if (view.selected == id || view.focused == id) {
      canvas.drawCircle(
        c,
        radius + 5 + pulse * 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = palette.ink.withValues(alpha: 0.8),
      );
    } else if (view.hovered == id) {
      canvas.drawCircle(
        c,
        radius + 4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = palette.ink.withValues(alpha: 0.45),
      );
    }
  }

  /// The connection from this device to the node it goes through: an arc
  /// of light, with particles flowing out along it.
  void link() {
    final current = view.scene.current;
    if (current == null) return;
    final from = Vec3.zero;
    final to =
        current.system.position + current.planet.offsetAt(view.orbitTime);
    if (view.migrations.containsKey(current.planet.id)) return;
    final rise = (to - from).length * 0.32 + 0.4;
    final control = from.lerp(to, 0.5) + Vec3(0, rise, 0);
    Vec3 at(double t) =>
        from * ((1 - t) * (1 - t)) + control * (2 * (1 - t) * t) + to * (t * t);
    final lines = GalaxyLines(40);
    final path = Path();
    var previous = at(0);
    var visible = false;
    for (var i = 1; i <= 40; i++) {
      final next = at(i / 40);
      final segment = clipWorldLine(
        previous,
        next,
        projection,
        (Offset.zero & size).inflate(8),
      );
      previous = next;
      if (segment == null) continue;
      visible = true;
      path.moveTo(segment.start.dx, segment.start.dy);
      path.lineTo(segment.end.dx, segment.end.dy);
      lines.add(
        segment.start.dx,
        segment.start.dy,
        segment.end.dx,
        segment.end.dy,
      );
    }
    if (!visible) return;
    final light = palette.signal;
    final bounds = path.getBounds().inflate(1);
    final dim =
        view.selected == null ||
            view.selected == homeId ||
            view.selected == current.planet.id ||
            view.selected == current.system.id
        ? 1.0
        : 0.35;
    if (!view.scene.connected) {
      // Configured but stopped: a faint dashed course, nothing flowing.
      final dash = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round
        ..color = light.withValues(alpha: (dark ? 0.4 : 0.35) * dim);
      lines.draw(canvas, dash, dashed: true);
      return;
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = light.withValues(alpha: (dark ? 0.12 : 0.08) * dim),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            light.withValues(alpha: (dark ? 0.75 : 0.6) * dim),
            light.withValues(alpha: (dark ? 0.3 : 0.25) * dim),
          ],
        ).createShader(bounds),
    );
    for (var k = 0; k < 4; k++) {
      final t = view.still ? (k + 1) / 5 : (view.time * 0.25 + k / 4) % 1.0;
      final p = projection.at(at(t));
      if (p == null || !_visible(p.point, 16)) continue;
      _glow(p.point, dark ? 2.3 : 1.9, light.withValues(alpha: 0.9 * dim));
    }
  }

  void ghosts() {
    view.ghosts.removeWhere((g) => view.time - g.since > 1.0);
    for (final ghost in view.ghosts) {
      final p = projection.at(ghost.position);
      if (p == null) continue;
      final t = (view.time - ghost.since).clamp(0.0, 1.0);
      if (!_visible(p.point, 140)) continue;
      _sphere(
        p.point,
        (ghost.size * p.scale).clamp(2.0, 14.0) * (1 + t * 0.4),
        palette.scheme.outline,
        1 - t,
      );
    }
  }

  TextStyle _baseStyle() => palette.text.copyWith(
    fontSize: 11.5,
    color: palette.ink.withValues(alpha: dark ? 0.78 : 0.74),
    letterSpacing: 0.1,
    height: 1.25,
    shadows: [
      Shadow(
        color: (dark ? Colors.black : Colors.white).withValues(
          alpha: dark ? 0.9 : 0.95,
        ),
        offset: const Offset(0, 1),
        blurRadius: 1,
      ),
    ],
  );

  TextSpan _strongSpan(String text) => TextSpan(
    text: text,
    style: _baseStyle().copyWith(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: palette.ink.withValues(alpha: dark ? 0.94 : 0.9),
    ),
  );

  TextPainter _text(String key, InlineSpan Function() span) =>
      painter.labels.of('${dark ? 'd' : 'l'}|$key', span);

  /// Place labels most important first; one that would overlap a placed
  /// label, or lie over a star, is left out unless it is emphasised.
  void labels() {
    pending.sort((a, b) => b.rank.compareTo(a.rank));
    final placed = <Rect>[];
    var shown = 0;
    for (final label in pending) {
      final emphasis = label.rank >= 4;
      if (shown >= 48 && !emphasis) break;
      final text = label.painter;
      final offset = Offset(
        label.anchor.dx - text.width / 2,
        label.anchor.dy + label.gap,
      );
      final rect = (offset & text.size).inflate(2);
      if (rect.right < 0 ||
          rect.left > size.width ||
          rect.top > size.height ||
          rect.bottom < 0) {
        continue;
      }
      if (!emphasis &&
          (placed.any(rect.overlaps) || obstacles.any(rect.overlaps))) {
        continue;
      }
      placed.add(rect);
      text.paint(canvas, offset);
      shown++;
    }
  }
}

/// Submit equal-texture planets together while retaining each system's depth
/// order. The per-sprite colour carries opacity without offscreen layers.
class _SpriteBatch {
  final _groups =
      <
        ui.Image,
        ({List<double> transforms, List<double> rects, List<int> colors})
      >{};

  void add(ui.Image image, Offset center, double radius, double opacity) {
    final group = _groups.putIfAbsent(
      image,
      () => (transforms: [], rects: [], colors: []),
    );
    final scale = radius / PlanetAtlas.radius;
    group.transforms.addAll([
      scale,
      0,
      center.dx - image.width * scale / 2,
      center.dy - image.height * scale / 2,
    ]);
    group.rects.addAll([0, 0, image.width.toDouble(), image.height.toDouble()]);
    group.colors.add(Colors.white.withValues(alpha: opacity).toARGB32());
  }

  void draw(Canvas canvas) {
    for (final entry in _groups.entries) {
      final group = entry.value;
      canvas.drawRawAtlas(
        entry.key,
        Float32List.fromList(group.transforms),
        Float32List.fromList(group.rects),
        Int32List.fromList(group.colors),
        BlendMode.modulate,
        null,
        Paint()..filterQuality = FilterQuality.low,
      );
    }
    _groups.clear();
  }
}
