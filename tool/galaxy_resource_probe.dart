// Local performance harness: fvm flutter run --release -t tool/galaxy_resource_probe.dart
// Uses synthetic nodes, never opens a proxy or changes VPN settings.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:proxy_ui/src/models/node_health.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_canvas.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_geometry.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_model.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_painter.dart';
import 'package:proxy_ui/src/theme/app_theme.dart';
import 'package:proxy_ui/src/widgets/app_render_activity.dart';
import 'package:proxy_ui/src/services/window_state_service.dart';
import 'package:window_manager/window_manager.dart';

const _output = String.fromEnvironment('GALAXY_PROBE_OUTPUT');
bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_desktop) {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('Galaxy resource probe');
    await windowManager.setSize(const Size(1280, 720));
  }
  runApp(
    MaterialApp(
      theme: buildAppTheme(Colors.indigo, Brightness.dark),
      home: const AppRenderActivity(child: _Probe()),
    ),
  );
}

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

  late final _scene = buildGalaxyScene([
    for (var i = 0; i < 240; i++)
      GalaxyNode(
        node: NodeInfo(
          nodeId: 'node-$i',
          addr: '192.0.2.${i + 1}:1081',
          lastSeen: DateTime(2026),
          country: '',
          region: '',
        ),
        country: const [
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
        ][i % 12],
        health: NodeHealth.fast,
        current: i == 0,
        latencyMs: 120,
      ),
  ], connected: true);
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
      });
    }
  }

  void _onTimings(List<FrameTiming> timings) => _timings.addAll(timings);

  void _measure(
    String phase, {
    Duration duration = const Duration(seconds: 15),
  }) {
    _report?.cancel();
    _timings.clear();
    final sample = ++_sample;
    _log({'event': 'start', 'phase': phase, 'sample': sample});
    _report = Timer(duration, () {
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
          'p50_us': percentile(0.5),
          'p95_us': percentile(0.95),
          'max_us': percentile(1),
          'over_16ms': values.where((value) => value > 16667).length,
          'over_33ms': values.where((value) => value > 33333).length,
        };
      }

      _log({
        'event': 'end',
        'phase': phase,
        'sample': sample,
        'frames': _timings.length,
        'build_us': build,
        'raster_us': raster,
        'rss_bytes': ProcessInfo.currentRss,
        'build': distribution([
          for (final frame in _timings) frame.buildDuration.inMicroseconds,
        ]),
        'raster': distribution([
          for (final frame in _timings) frame.rasterDuration.inMicroseconds,
        ]),
      });
      _timings.clear();
    });
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
