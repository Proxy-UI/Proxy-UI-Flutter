/// The interactive galaxy: drag to orbit, scroll or pinch to zoom, click a
/// country or a node to inspect it, arrows and Enter from the keyboard.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_theme.dart';
import 'flag_atlas.dart';
import 'galaxy_backdrop.dart';
import 'galaxy_geometry.dart';
import 'galaxy_model.dart';
import 'galaxy_painter.dart';
import 'galaxy_view.dart';
import 'planet_atlas.dart';

/// Camera commands from outside the canvas.
class GalaxyController {
  _GalaxyCanvasState? _state;

  /// Back to the whole galaxy, as it was first framed.
  void reset() => _state?._reset();
}

class GalaxyCanvas extends StatefulWidget {
  const GalaxyCanvas({
    super.key,
    required this.scene,
    required this.text,
    required this.selected,
    required this.onSelect,
    this.controller,
    this.semanticLabel,
    this.inset = EdgeInsets.zero,
  });

  final GalaxyScene scene;

  /// The part of the canvas covered by controls floating over it.
  final EdgeInsets inset;
  final GalaxyText text;

  /// The selected body: [homeId], a system id or a node id.
  final String? selected;
  final ValueChanged<String?> onSelect;
  final GalaxyController? controller;
  final String? semanticLabel;

  @override
  State<GalaxyCanvas> createState() => _GalaxyCanvasState();
}

class _GalaxyCanvasState extends State<GalaxyCanvas>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final GalaxyView _view = GalaxyView();
  final LabelCache _labels = LabelCache();
  final Starfield _stars = Starfield();
  final BackdropCache _backdrop = BackdropCache();
  final PlanetAtlas _planets = PlanetAtlas();
  final GalaxyGeometry _geometry = GalaxyGeometry();
  final FocusNode _focus = FocusNode(debugLabel: 'galaxy');
  late final Ticker _frameTicker;
  Duration _last = Duration.zero;
  double _touched = -6;
  bool _foreground = true;
  bool _enabled = false;
  bool _settled = true;
  bool _first = true;
  double _pinch = 1;
  double _fittedReach = 0;
  Size _canvas = Size.zero;

  /// After this long without input the camera glides back to the galaxy.
  static const _glideAfter = 6.0;

  @override
  void initState() {
    super.initState();
    _frameTicker = createTicker(_onTick);
    widget.controller?._state = this;
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _view.selected = widget.selected;
    _view.camera.inset = widget.inset;
    _view.update(widget.scene, first: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view.still = MediaQuery.disableAnimationsOf(context);
    _view.expireTransitions();
    _syncActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncActivity();
  }

  void _syncActivity() {
    final enabled = _foreground && TickerMode.valuesOf(context).enabled;
    if (enabled == _enabled) return;
    _enabled = enabled;
    _planets.enabled = enabled;
    _backdrop.enabled = enabled;
    if (enabled) {
      FlagAtlas.instance.addListener(_wake);
      _wake();
    } else {
      _stopFrames();
      _geometry.dispose();
      _last = Duration.zero;
      FlagAtlas.instance.removeListener(_wake);
      _labels.dispose();
    }
  }

  @override
  void didUpdateWidget(GalaxyCanvas old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._state = null;
      widget.controller?._state = this;
    }
    if (old.text != widget.text) _labels.dispose();
    if (!identical(old.scene, widget.scene)) {
      _view.update(widget.scene, first: _first && widget.scene.isEmpty);
      final reach = widget.scene.reach;
      if ((reach - _fittedReach).abs() > 0.5) _refit(entrance: _first);
      _wake();
    }
    if (old.selected != widget.selected) {
      _focusOn(widget.selected);
    }
    if (old.inset != widget.inset) {
      _view.camera.inset = widget.inset;
      _refit(entrance: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FlagAtlas.instance.removeListener(_wake);
    if (widget.controller?._state == this) widget.controller?._state = null;
    _stopFrames();
    _frameTicker.dispose();
    _focus.dispose();
    _view.dispose();
    _labels.dispose();
    _backdrop.dispose();
    _stars.dispose();
    _planets.dispose();
    _geometry.dispose();
    super.dispose();
  }

  bool get _ambient => !_view.still && _view.time - _touched < _glideAfter;

  bool get _needsFrames => _ambient || !_view.camera.settled || _view.busy;

  void _onTick(Duration elapsed) {
    if (!_enabled) return;
    final seconds = (elapsed - _last).inMicroseconds / 1e6;
    final dt = seconds.clamp(0.0, 0.05);
    _last = elapsed;
    final camera = _view.camera;
    final idle = !_ambient;
    if (idle && !_settled && _view.selected == null) {
      camera.overview();
      _settled = true;
    }
    if (_view.selected case final id?) {
      final at = _view.positionOf(id);
      if (at != null) camera.goalTarget = at;
    }
    camera.step(dt, drifting: _ambient && _view.selected == null);
    // Slow rasterization must not stretch a six-second interaction into a
    // much longer animation. Only camera integration needs a bounded step.
    _view.time += seconds;
    if (_ambient) _view.motionTime += dt;
    _view.expireTransitions();
    _view.tick();
    if (!_needsFrames) _stopFrames();
  }

  /// Draw frames again: something moved, changed or was asked for.
  void _wake() {
    if (!mounted || !_enabled) return;
    if (_frameTicker.isActive) return;
    _view.tick();
    if (!_needsFrames) return;
    _last = Duration.zero;
    // Follow display vsync during interaction; stop requesting engine frames
    // entirely once the finite animation settles or the view is hidden.
    _frameTicker.start();
  }

  void _stopFrames() {
    _frameTicker.stop();
  }

  void _touch() {
    _touched = _view.time;
    _settled = false;
    _wake();
  }

  void _refit({required bool entrance}) {
    final scene = _view.scene;
    _fittedReach = scene.reach;
    final camera = _view.camera
      ..home = scene.isEmpty ? Vec3.zero : scene.center
      ..fit(scene.isEmpty ? 6.0 : scene.radius, _canvas);
    if (entrance) {
      // The galaxy arrives from a little further out.
      camera
        ..overview()
        ..target = camera.home
        ..distance = camera.fitDistance * 1.4;
    } else if (_view.selected == null) {
      camera.overview();
    }
    _wake();
  }

  void _focusOn(String? id) {
    _view.selected = id;
    _touch();
    final camera = _view.camera;
    if (id == null) {
      camera.overview();
      return;
    }
    if (id == homeId) {
      camera.focus(Vec3.zero, camera.fitDistance * 0.55);
      return;
    }
    final system = _view.scene.systemOf(id);
    final at = _view.positionOf(id);
    if (at == null) return;
    camera.focus(at, system != null ? 3.6 + system.extent * 3.4 : 3.0);
  }

  void _zoom(double factor) {
    _view.camera.zoom(factor);
    _touch();
  }

  void _reset() {
    _view.camera.spin = 0;
    widget.onSelect(null);
    _view.camera.overview();
    _touch();
  }

  void _tap(Offset point) {
    _focus.requestFocus();
    widget.onSelect(_view.hitAt(point)?.id);
  }

  void _hover(Offset point) {
    final id = _view.hitAt(point)?.id;
    if (id != _view.hovered) {
      setState(() => _view.hovered = id);
      _wake();
    }
  }

  List<String> get _order => [
    homeId,
    for (final system in _view.scene.systems) ...[
      system.id,
      for (final planet in system.planets) planet.id,
    ],
  ];

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final order = _order;
    final key = event.logicalKey;
    final at = order.indexOf(_view.focused ?? _view.selected ?? '');
    void mark(String id) {
      setState(() => _view.focused = id);
      _touch();
    }

    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      mark(order[(at + 1) % order.length]);
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      mark(order[(at - 1 + order.length) % order.length]);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      widget.onSelect(_view.focused ?? order.first);
    } else if (key == LogicalKeyboardKey.escape && _view.selected != null) {
      widget.onSelect(null);
    } else if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      _zoom(1.25);
    } else if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _zoom(1 / 1.25);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    if (still != _view.still) {
      _view.still = still;
      WidgetsBinding.instance.addPostFrameCallback((_) => _wake());
    }
    final palette = GalaxyPalette(
      scheme: theme.colorScheme,
      status: StatusColors.of(context),
      ratio: MediaQuery.devicePixelRatioOf(context),
      text: theme.textTheme.bodySmall ?? const TextStyle(),
    );
    _planets.palette(palette.scheme);
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvas = constraints.biggest;
        if (canvas != _canvas) {
          _canvas = canvas;
          final entrance = _first;
          _first = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _refit(entrance: entrance);
          });
        }
        return Semantics(
          label: widget.semanticLabel,
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _key,
            child: Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  final dy = event.scrollDelta.dy;
                  _zoom(math.pow(1.0018, -dy).toDouble());
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (_) {
                  _pinch = 1;
                  _view.camera.spin = 0;
                  _touch();
                },
                onScaleUpdate: (details) {
                  if (details.scale != 1 && details.pointerCount != 1) {
                    _view.camera.zoom(details.scale / _pinch);
                    _pinch = details.scale;
                  }
                  _view.camera.drag(
                    details.focalPointDelta.dx,
                    details.focalPointDelta.dy,
                  );
                  _touch();
                },
                onScaleEnd: (details) {
                  _view.camera.spin =
                      -details.velocity.pixelsPerSecond.dx * 0.004;
                  _touch();
                },
                onTapUp: (details) => _tap(details.localPosition),
                child: MouseRegion(
                  cursor: _view.hovered == null
                      ? SystemMouseCursors.grab
                      : SystemMouseCursors.click,
                  onHover: (event) => _hover(event.localPosition),
                  onExit: (_) {
                    if (_view.hovered == null) return;
                    setState(() => _view.hovered = null);
                    _wake();
                  },
                  child: RepaintBoundary(
                    child: CustomPaint(
                      key: const Key('galaxy-canvas'),
                      size: Size.infinite,
                      painter: GalaxyPainter(
                        view: _view,
                        palette: palette,
                        text: widget.text,
                        labels: _labels,
                        starfield: _stars,
                        backdrop: _backdrop,
                        planets: _planets,
                        geometry: _geometry,
                        onBackdrop: _wake,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
