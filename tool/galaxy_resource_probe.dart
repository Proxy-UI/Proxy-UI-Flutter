// Local performance harness: fvm flutter run --release -t tool/galaxy_resource_probe.dart
// Uses synthetic nodes, never opens a proxy or changes VPN settings.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:proxy_ui/src/models/node_health.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_canvas.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_geometry.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_model.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_painter.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/planet_atlas.dart';
import 'package:proxy_ui/src/theme/app_theme.dart';
import 'package:proxy_ui/src/widgets/app_render_activity.dart';
import 'package:proxy_ui/src/services/window_state_service.dart';
import 'package:window_manager/window_manager.dart';

const _output = String.fromEnvironment('GALAXY_PROBE_OUTPUT');
const _suiteName = String.fromEnvironment('GALAXY_PROBE_SUITE');
bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// The probe's theme, switched by the raster suite.
final _brightness = ValueNotifier(Brightness.dark);

/// Times another app took focus during the raster suite.
var _focusLosses = 0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_desktop) {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('Galaxy resource probe');
    await windowManager.setSize(const Size(1280, 720));
    if (_suiteName == 'raster') await _pin();
  }
  if (_suiteName == 'raster') {
    // The Mac may be in use. Losing focus mutes the galaxy, so the suite
    // keeps it from reaching the app and counts it instead.
    SystemChannels.lifecycle.setMessageHandler((message) async {
      final state = AppLifecycleState.values
          .where((state) => state.toString() == message)
          .firstOrNull;
      if (state == AppLifecycleState.inactive) {
        _focusLosses++;
      } else if (state != null) {
        // What the binding's own handler does with the message.
        // ignore: invalid_use_of_protected_member
        ServicesBinding.instance.handleAppLifecycleStateChanged(state);
      }
      return null;
    });
  }
  runApp(
    ValueListenableBuilder(
      valueListenable: _brightness,
      builder: (context, brightness, _) => MaterialApp(
        theme: buildAppTheme(Colors.indigo, brightness),
        // Nor does the raster suite mute the galaxy on window blur.
        home: _suiteName == 'raster'
            ? const _Probe()
            : const AppRenderActivity(child: _Probe()),
      ),
    ),
  );
}

/// Keep the window on top of the main display: macOS stops drawing a covered
/// window, and another display may run at another pixel ratio and refresh
/// rate, so its frames would not compare.
Future<void> _pin() async {
  await windowManager.setPosition(const Offset(80, 80));
  await windowManager.setAlwaysOnTop(true);
  await windowManager.setVisibleOnAllWorkspaces(true);
}

const _countries = [
  'US',
  'JP',
  'SG',
  'HK',
  'DE',
  'GB',
  'FR',
  'AU',
  'CA',
  'KR',
  'NL',
  'IN',
];

/// Mostly healthy nodes, with every other state among them.
const _healths = [
  NodeHealth.fast,
  NodeHealth.fast,
  NodeHealth.fast,
  NodeHealth.fair,
  NodeHealth.slow,
  NodeHealth.unreachable,
  NodeHealth.untested,
  NodeHealth.testing,
];

GalaxyScene _syntheticScene(int count, int countries, {bool mixed = false}) =>
    buildGalaxyScene([
      for (var i = 0; i < count; i++)
        GalaxyNode(
          node: NodeInfo(
            nodeId: 'node-$i',
            addr: '192.0.2.${i + 1}:1081',
            lastSeen: DateTime(2026),
            country: '',
            region: '',
          ),
          country: _countries[i % countries],
          health: mixed ? _healths[i % _healths.length] : NodeHealth.fast,
          current: i == 0,
          latencyMs: 120,
        ),
    ], connected: true);

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with WidgetsBindingObserver {
  final _controller = GalaxyController();
  final _timings = <FrameTiming>[];
  Timer? _report;
  bool _showGalaxy = false;
  int _sample = 0;
  bool _suite = false;
  String? _selected;

  void _log(Map<String, Object?> event) {
    final line = jsonEncode({
      ...event,
      'pid': pid,
      'platform': Platform.operatingSystem,
      'native_geometry': GeometryBatch.nativeAvailable,
      'utc_ms': DateTime.now().millisecondsSinceEpoch,
    });
    debugPrint('GALAXY_PROBE $line');
    if (_output.isNotEmpty) {
      File(_output).writeAsStringSync('$line\n', mode: FileMode.append);
    }
  }

  /// The probe's own scene, and the raster suite's two.
  late final _default = _syntheticScene(240, 12);
  late final _scenes = {
    'typical': _syntheticScene(36, 6, mixed: true),
    'busy': _syntheticScene(240, 12, mixed: true),
  };
  late GalaxyScene _scene = _default;
  final _text = GalaxyText(
    home: 'Home',
    unlocated: 'Unknown',
    countryName: (code) => code,
    countryStats: (total, available) => '$available / $total',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _measure('baseline');
    const suite = String.fromEnvironment('GALAXY_PROBE_SUITE');
    if (suite.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (suite == 'hierarchy') _hierarchySuite();
        if (suite == 'desktop') _desktopSuite();
        if (suite == 'raster') _rasterSuite();
      });
    }
  }

  void _onTimings(List<FrameTiming> timings) => _timings.addAll(timings);

  /// Sample frame timings for [duration]; completes with the logged result.
  Future<Map<String, Object?>> _measure(
    String phase, {
    Duration duration = const Duration(seconds: 15),
  }) {
    _report?.cancel();
    _timings.clear();
    final focusLosses = _focusLosses;
    final done = Completer<Map<String, Object?>>();
    final sample = ++_sample;
    final started = DateTime.now().millisecondsSinceEpoch;
    _log({'event': 'start', 'phase': phase, 'sample': sample});
    _report = Timer(duration, () {
      if (!mounted) return;
      final build = _timings.fold<int>(
        0,
        (sum, frame) => sum + frame.buildDuration.inMicroseconds,
      );
      final raster = _timings.fold<int>(
        0,
        (sum, frame) => sum + frame.rasterDuration.inMicroseconds,
      );
      Map<String, Object> distribution(List<int> values) {
        values.sort();
        int percentile(double quantile) => values.isEmpty
            ? 0
            : values[((values.length - 1) * quantile).round()];
        return {
          'avg_us': values.isEmpty
              ? 0
              : (values.reduce((a, b) => a + b) / values.length).round(),
          'p50_us': percentile(0.5),
          'p90_us': percentile(0.9),
          'p95_us': percentile(0.95),
          'p99_us': percentile(0.99),
          'max_us': percentile(1),
          'over_16ms': values.where((value) => value > 16667).length,
          'over_33ms': values.where((value) => value > 33333).length,
        };
      }

      final view = View.of(context);
      final result = {
        'event': 'end',
        'phase': phase,
        'sample': sample,
        'frames': _timings.length,
        'ratio': view.devicePixelRatio,
        'refresh_hz': view.display.refreshRate.round(),
        'display': view.display.id,
        'size':
            '${view.physicalSize.width.round()}x'
            '${view.physicalSize.height.round()}',
        'started_ms': started,
        'build_us': build,
        'raster_us': raster,
        'rss_bytes': ProcessInfo.currentRss,
        'sprite_bytes': PlanetAtlas.liveBytes,
        'unfocused': _focusLosses - focusLosses,
        'build': distribution([
          for (final frame in _timings) frame.buildDuration.inMicroseconds,
        ]),
        'raster': distribution([
          for (final frame in _timings) frame.rasterDuration.inMicroseconds,
        ]),
      };
      _log(result);
      _timings.clear();
      done.complete(result);
    });
    return done.future;
  }

  /// Frame times while the camera moves, in a typical and a busy scene and
  /// both themes: the overview drifting, then flights between a country, one
  /// of its nodes and the overview. Each sample also reports resident memory
  /// and the planet images' bytes; its `started_ms`/`utc_ms` window lines up
  /// an outside `footprint` sampler, which counts the GPU memory RSS omits.
  Future<void> _rasterSuite() async {
    if (_suite) return;
    setState(() => _suite = true);
    Future<void> wait(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));
    final main = WidgetsBinding.instance.platformDispatcher.displays.first;
    // A sample counts only if it drew on the main display at its full rate:
    // otherwise the window was moved or covered, and it is taken again.
    bool valid(Map<String, Object?> result) =>
        result['display'] == main.id &&
        (result['frames']! as int) >= main.refreshRate * 8 * 0.85;
    Future<void> sample(String phase, Future<void> Function() drive) async {
      for (var attempt = 1; attempt <= 3 && mounted; attempt++) {
        if (_desktop) await _pin();
        final result = _measure(phase, duration: const Duration(seconds: 8));
        await drive();
        if (valid(await result)) return;
        _log({'event': 'retry', 'phase': phase, 'attempt': attempt});
      }
    }

    try {
      for (final name in _scenes.keys) {
        for (final brightness in [Brightness.dark, Brightness.light]) {
          if (!mounted) return;
          final label = '$name-${brightness.name}';
          _brightness.value = brightness;
          setState(() {
            _scene = _scenes[name]!;
            _selected = null;
            _showGalaxy = true;
          });
          // Let the entrance, the flags and the theme's images settle.
          for (var i = 0; i < 3; i++) {
            await wait(1000);
            _controller.reset();
          }
          await sample('raster-$label-overview', () async {
            for (var i = 0; i < 4; i++) {
              _controller.reset();
              await wait(2000);
            }
          });
          await sample('raster-$label-focus', () async {
            for (final id in [
              _scene.systems.first.id,
              _scene.systems.first.planets.first.id,
              _scene.systems[1].id,
              null,
            ]) {
              if (!mounted) return;
              setState(() => _selected = id);
              await wait(2000);
            }
          });
        }
      }
      _log({'event': 'raster-complete'});
    } finally {
      if (mounted) {
        setState(() {
          _suite = false;
          _scene = _default;
        });
      }
    }
  }

  Future<void> _hierarchySuite() async {
    if (_suite) return;
    setState(() {
      _suite = true;
      _showGalaxy = true;
      _selected = null;
    });
    await Future<void>.delayed(const Duration(seconds: 8));
    try {
      for (final system in _scene.systems.take(2)) {
        for (final selection in [
          (system.id, 'country'),
          (system.planets.first.id, 'node'),
          (system.id, 'return-country'),
          (null, 'overview'),
        ]) {
          if (!mounted) return;
          _measure(
            'hierarchy-${system.code}-${selection.$2}',
            duration: const Duration(seconds: 3),
          );
          setState(() => _selected = selection.$1);
          await Future<void>.delayed(const Duration(seconds: 4));
        }
      }
      _log({'event': 'hierarchy-complete'});
    } finally {
      if (mounted) setState(() => _suite = false);
    }
  }

  Future<void> _desktopSuite() async {
    if (_suite) return;
    setState(() => _suite = true);
    Future<void> settle([int seconds = 2]) =>
        Future<void>.delayed(Duration(seconds: seconds));
    Future<void> sample(String phase, [int seconds = 15]) async {
      if (!mounted) return;
      _measure(phase, duration: Duration(seconds: seconds));
      await settle(seconds + 1);
    }

    try {
      setState(() => _showGalaxy = false);
      await settle();
      await sample('windows-baseline-idle');
      if (!mounted) return;
      setState(() => _showGalaxy = true);
      await settle(10);
      await sample('windows-galaxy-idle');
      _controller.reset();
      await sample('windows-interaction', 8);
      _controller.reset();
      await windowManager.blur();
      await settle();
      await sample('windows-unfocused');
      await windowManager.focus();
      await settle(10);
      _controller.reset();
      await windowManager.minimize();
      await settle();
      await sample('windows-minimized');
      await windowManager.restore();
      await WindowStateService.instance.show();
      await windowManager.focus();
      await settle(10);
      await sample('windows-restored-idle');
      _controller.reset();
      await WindowStateService.instance.hide();
      await settle();
      await sample('windows-tray-hidden');
      await WindowStateService.instance.show();
      await windowManager.focus();
      await settle(10);
      await sample('windows-shown-idle');
    } finally {
      if (mounted) {
        await windowManager.restore();
        await WindowStateService.instance.show();
        setState(() => _suite = false);
        _log({'event': 'suite-complete'});
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _log({'event': 'lifecycle', 'state': state.name});
    if (_suite) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.resumed) {
      _measure('${_showGalaxy ? 'galaxy' : 'baseline'}-${state.name}');
    }
  }

  @override
  void dispose() {
    _report?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Galaxy resource probe')),
    body: Column(
      children: [
        AbsorbPointer(
          absorbing: _suite,
          child: Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: _hierarchySuite,
                child: const Text('Test hierarchy'),
              ),
              TextButton(
                onPressed: _rasterSuite,
                child: const Text('Test raster'),
              ),
              if (_desktop)
                TextButton(
                  onPressed: _suite ? null : _desktopSuite,
                  child: Text(
                    _suite ? 'Desktop suite running' : 'Run desktop suite',
                  ),
                ),
              TextButton(
                onPressed: () {
                  setState(() => _showGalaxy = false);
                  _measure('baseline');
                },
                child: const Text('Baseline'),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _showGalaxy = true);
                  _measure('galaxy-enter');
                },
                child: const Text('Galaxy'),
              ),
              TextButton(
                onPressed: () => _measure('idle'),
                child: const Text('Measure idle'),
              ),
              TextButton(
                onPressed: () {
                  _controller.reset();
                  _measure('interaction');
                },
                child: const Text('Animate'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _showGalaxy
              ? IgnorePointer(
                  ignoring: _suite,
                  child: GalaxyCanvas(
                    key: ObjectKey(_scene),
                    scene: _scene,
                    text: _text,
                    selected: _selected,
                    onSelect: (selected) =>
                        setState(() => _selected = selected),
                    controller: _controller,
                  ),
                )
              : const SizedBox.expand(),
        ),
      ],
    ),
  );
}
