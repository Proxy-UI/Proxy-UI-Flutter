// Local performance harness for testing a whole country at once:
//   fvm flutter run --profile -d macos -t tool/node_test_burst_probe.dart
// Synthetic nodes; never opens a proxy or changes saved settings.
//
// BURST_PATH selects how probes run:
//   isolate  one isolate per probe, blocked for as long as it takes, eight at
//            a time: what a native library without the batch API does
//   batch    a model of the native batch: timers, sixteen at a time
//   real     the real native batch, against local ports that refuse or never
//            answer; needs a freshly staged native library
import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/models/node_catalog_preferences.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_model.dart';
import 'package:proxy_ui/src/screens/nodes/node_actions.dart';
import 'package:proxy_ui/src/screens/nodes/nodes_page.dart';
import 'package:proxy_ui/src/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toastification/toastification.dart';
import 'package:window_manager/window_manager.dart';

/// Nodes in the country under test; the rest of the catalogue stays idle.
const _burst = int.fromEnvironment('BURST_NODES', defaultValue: 30);

/// How long an unreachable node takes to give up, as the native probe does.
const _timeoutMs = int.fromEnvironment('BURST_TIMEOUT_MS', defaultValue: 10000);

const _output = String.fromEnvironment('BURST_OUTPUT');

/// The body selected while testing: a country opens its panel of rows.
const _select = String.fromEnvironment('BURST_SELECT', defaultValue: 'US');

const _path = String.fromEnvironment('BURST_PATH', defaultValue: 'isolate');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('Node test burst probe');
    await windowManager.setSize(const Size(1440, 900));
    // An occluded window draws nothing, which would read as a perfect result.
    await windowManager.setAlwaysOnTop(true);
  }
  // In memory, so the harness can never read or overwrite real settings.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({
    'node_catalog_preferences': jsonEncode(
      (_path == 'real' ? await _localCatalogue() : _catalogue()).toJson(),
    ),
  });
  final state = ProxyState(service: _BurstService());
  runApp(
    ToastificationWrapper(
      child: ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Colors.indigo, Brightness.dark),
          home: const Scaffold(body: _Burst()),
        ),
      ),
    ),
  );
}

class _Burst extends StatefulWidget {
  const _Burst();
  @override
  State<_Burst> createState() => _BurstState();
}

class _BurstState extends State<_Burst> with WidgetsBindingObserver {
  final _timings = <FrameTiming>[];

  /// An inactive app mutes the galaxy, so a sample is only valid while the
  /// app stays resumed throughout.
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_timings.addAll);
    unawaited(_run());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _resumed = false;
  }

  Future<void> _run() async {
    final state = context.read<ProxyState>();
    while (!state.isInitialized) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Let the galaxy's entrance settle so it is not measured as the burst.
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!mounted) return;
    final targets = [
      for (final node in state.nodes)
        if (state.effectiveCountry(node) == 'US') node,
    ];

    var notifications = 0;
    void count() => notifications++;
    state.addListener(count);

    // A UI-isolate heartbeat: anything holding the event loop shows up as a
    // gap, whether or not a frame was scheduled at the time.
    final clock = Stopwatch()..start();
    var last = 0;
    var maxGap = 0;
    var blocked = 0;
    final heartbeat = Timer.periodic(const Duration(milliseconds: 4), (_) {
      final now = clock.elapsedMicroseconds;
      final gap = now - last;
      last = now;
      if (gap > maxGap) maxGap = gap;
      if (gap > 20000) blocked += gap - 4000;
    });

    final cpuBefore = _cpuSeconds();
    _timings.clear();
    _resumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final startedAt = Timeline.now;
    final actions = NodeActions(state);
    await actions.testMany(context, targets);
    final testedIn = clock.elapsedMilliseconds;
    // Trailing ripples and migrations are part of the cost.
    await Future<void>.delayed(const Duration(seconds: 2));
    heartbeat.cancel();
    state.removeListener(count);
    actions.dispose();
    final cpu = _cpuSeconds() - cpuBefore;

    Map<String, Object> distribution(List<int> values) {
      values.sort();
      int at(double q) =>
          values.isEmpty ? 0 : values[((values.length - 1) * q).round()];
      return {
        'p50_ms': at(0.5) / 1000,
        'p95_ms': at(0.95) / 1000,
        'max_ms': at(1) / 1000,
        'sum_ms': values.fold<int>(0, (a, b) => a + b) / 1000,
      };
    }

    final line = jsonEncode({
      'valid': _resumed,
      'path': _path,
      'select': _select,
      'nodes': targets.length,
      'catalogue': state.nodes.length,
      'tested_ms': testedIn,
      'frames': _timings.length,
      'build': distribution([
        for (final t in _timings) t.buildDuration.inMicroseconds,
      ]),
      'raster': distribution([
        for (final t in _timings) t.rasterDuration.inMicroseconds,
      ]),
      'frames_over_16ms': _timings
          .where((t) => t.totalSpan.inMicroseconds > 16667)
          .length,
      'frames_over_33ms': _timings
          .where((t) => t.totalSpan.inMicroseconds > 33333)
          .length,
      // When the slowest builds happened, relative to the start of the test.
      'slowest_builds': [
        for (final t in ([
          ..._timings,
        ]..sort((a, b) => b.buildDuration.compareTo(a.buildDuration))).take(3))
          {
            'at_ms':
                (t.timestampInMicroseconds(FramePhase.buildStart) -
                    startedAt) ~/
                1000,
            'build_ms': t.buildDuration.inMicroseconds / 1000,
          },
      ],
      // Frames drawn in each half second since the test started: drawing
      // should come in short bursts as answers arrive, not continuously.
      'frames_per_500ms': () {
        final buckets = List<int>.filled(testedIn ~/ 500 + 5, 0);
        for (final t in _timings) {
          final at =
              (t.timestampInMicroseconds(FramePhase.buildStart) - startedAt) ~/
              500000;
          if (at >= 0 && at < buckets.length) buckets[at]++;
        }
        return buckets;
      }(),
      'ui_max_gap_ms': maxGap / 1000,
      'ui_blocked_ms': blocked / 1000,
      'provider_notifications': notifications,
      'answered': state.nodes
          .where((node) => targets.contains(node))
          .where((node) => state.verificationFor(node) != null)
          .length,
      'process_cpu_s': cpu,
    });
    debugPrint('BURST_PROBE $line');
    if (_output.isNotEmpty) {
      File(_output).writeAsStringSync('$line\n', mode: FileMode.append);
    }
    exit(0);
  }

  @override
  // A stray scroll over the galaxy would start an interaction of its own.
  Widget build(BuildContext context) => IgnorePointer(
    child: NodesPage(
      initialSelection: _select == 'none' ? null : systemIdFor(_select),
    ),
  );
}

double _cpuSeconds() {
  final result = Process.runSync('ps', ['-o', 'time=', '-p', '$pid']);
  final parts = (result.stdout as String).trim().split(':');
  var seconds = 0.0;
  for (final part in parts) {
    seconds = seconds * 60 + (double.tryParse(part) ?? 0);
  }
  return seconds;
}

/// About half the country answers within a second; the rest time out, which
/// matches a real catalogue where a dead node costs the whole timeout.
({bool success, int latencyMs}) _outcome(int index) {
  final success = index.isEven;
  return (
    success: success,
    latencyMs: success ? 150 + (index * 97) % 800 : _timeoutMs,
  );
}

int _indexOf(String host) => int.parse(host.split('.').last) - 10;

NodeProbe _probeOf(String host, ({bool success, int latencyMs}) outcome) =>
    outcome.success
    ? NodeProbe(
        success: true,
        countryCode: 'US',
        egressIp: host,
        latencyMs: outcome.latencyMs,
      )
    : NodeProbe(
        success: false,
        latencyMs: outcome.latencyMs,
        error: 'timed out waiting for an answer through the node',
      );

class _BurstService extends ProxyService {
  @override
  void initLogging() {}
  @override
  void setLogLevel(int level) {}
  @override
  bool restoreOrphanedSystemProxy() => false;
  @override
  bool get isRunning => false;
  @override
  bool get isTunRunning => false;
  @override
  bool get isElevated => true;
  @override
  String? get lastError => null;
  @override
  void dispose() {}

  @override
  Stream<(int, NodeProbe)> probeNodes(
    List<NodeProbeTarget> targets, {
    bool secureTransport = false,
    int timeoutMs = 10000,
  }) {
    if (_path == 'real') {
      return super.probeNodes(
        targets,
        secureTransport: secureTransport,
        timeoutMs: timeoutMs,
      );
    }
    // Batch probes are tasks on the native runtime, and each answer arrives
    // as one message on the UI isolate. Without the batch, each probe is an
    // isolate blocked in a native call, as many at once as there are workers.
    final concurrency = _path == 'batch'
        ? ProxyService.batchProbeConcurrency
        : ProxyService.isolateProbeConcurrency;
    late final StreamController<(int, NodeProbe)> results;
    var next = 0;
    var running = 0;
    void start() {
      while (running < concurrency && next < targets.length) {
        final index = next++;
        final host = targets[index].host;
        final outcome = _outcome(_indexOf(host));
        running++;
        final answered = _path == 'batch'
            ? Future<void>.delayed(Duration(milliseconds: outcome.latencyMs))
            : compute(_blockingProbe, outcome.latencyMs);
        answered.then((_) {
          running--;
          results.add((index, _probeOf(host, outcome)));
          if (next == targets.length && running == 0) {
            results.close();
          } else {
            start();
          }
        });
      }
    }

    results = StreamController(onListen: start);
    return results.stream;
  }
}

int _blockingProbe(int milliseconds) {
  sleep(Duration(milliseconds: milliseconds));
  return Isolate.current.hashCode;
}

/// The catalogue with the country under test on this machine: alternately a
/// closed port, which refuses at once, and a listener that never answers, so
/// those probes run to their timeout.
Future<NodeCatalogPreferences> _localCatalogue() async {
  final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final refusing = closed.port;
  await closed.close();
  final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final held = <Socket>[];
  silent.listen(held.add);
  final catalogue = _catalogue();
  var index = 0;
  final nodes = [
    for (final node in catalogue.nodes)
      if (catalogue.verificationFor(node)?.countryCode == 'US')
        NodeInfo(
          nodeId: node.nodeId,
          addr: '127.0.0.1:${(index++).isEven ? refusing : silent.port}',
          lastSeen: node.lastSeen,
          country: '',
          region: '',
        )
      else
        node,
  ];
  return catalogue.copyWith(
    nodes: nodes,
    verifications: {
      for (var i = 0; i < nodes.length; i++)
        nodes[i].storageKey: catalogue.verificationFor(catalogue.nodes[i])!,
    },
  );
}

/// A catalogue shaped like a real one: one large country under test, a few
/// smaller ones, and a cluster that never answered.
NodeCatalogPreferences _catalogue() {
  final checked = DateTime.now().subtract(const Duration(minutes: 3));
  final nodes = <NodeInfo>[];
  final verifications = <String, NodeVerification>{};
  var octet = 10;
  void add(String country, int count, {int? latency}) {
    for (var i = 0; i < count; i++) {
      final addr = '203.0.113.${octet++}:1081';
      final node = NodeInfo(
        nodeId: addr,
        addr: addr,
        lastSeen: checked,
        country: '',
        region: '',
      );
      nodes.add(node);
      verifications[node.storageKey] = country.isEmpty
          ? NodeVerification(
              status: NodeVerificationStatus.unreachable,
              checkedAt: checked,
              error: 'timed out waiting for an answer through the node',
            )
          : NodeVerification(
              status: NodeVerificationStatus.verified,
              checkedAt: checked,
              countryCode: country,
              egressIp: addr.split(':').first,
              latencyMs: latency ?? 120 + (octet * 37) % 700,
            );
    }
  }

  add('US', _burst);
  add('HK', 6);
  add('SG', 4);
  add('JP', 3);
  add('DE', 2);
  add('GB', 2);
  add('KR', 1);
  add('', 8);
  return NodeCatalogPreferences(
    serverHost: '203.0.113.10',
    nodes: nodes,
    fetchedAt: checked,
    verifications: verifications,
  );
}
