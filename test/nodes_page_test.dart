import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/ffi/proxy_ffi.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/models/quic_support.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_canvas.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_model.dart';
import 'package:proxy_ui/src/screens/nodes/nodes_page.dart';
import 'package:proxy_ui/src/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toastification/toastification.dart';

import 'support/fake_proxy_service.dart';

Future<ProxyState> _state(WidgetTester tester, FakeProxyService service) async {
  late ProxyState state;
  await tester.runAsync(() async {
    state = ProxyState(service: service);
    while (!state.isInitialized) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  addTearDown(state.dispose);
  return state;
}

Widget _app(ProxyState state, {String? selection}) => ToastificationWrapper(
  child: ChangeNotifierProvider.value(
    value: state,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildAppTheme(Colors.indigo, Brightness.dark),
      home: Scaffold(body: NodesPage(initialSelection: selection)),
    ),
  ),
);

void main() {
  setUp(() {
    final catalogue = sampleCatalogue();
    SharedPreferences.setMockInitialValues(
      samplePreferences(catalogue, current: catalogue.nodes[1].addr),
    );
  });

  testWidgets('the galaxy is the default view and a node shows its address', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = await _state(tester, FakeProxyService());

    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();
    final canvas = tester.widget<GalaxyCanvas>(find.byType(GalaxyCanvas));
    expect(
      canvas.scene.systems.map((s) => s.code),
      containsAll(['US', 'HK', 'SG', 'JP', '']),
    );
    expect(canvas.scene.current?.planet.node.node.addr, state.nodes[1].addr);

    canvas.onSelect(state.nodes[0].storageKey);
    await tester.pumpAndSettle();
    expect(find.text('203.0.113.10'), findsWidgets);
    expect(find.text('Connect'), findsOneWidget);

    // The list shows the same selection and the same addresses.
    await tester.tap(find.text('List'));
    await tester.pumpAndSettle();
    expect(find.byType(GalaxyCanvas), findsNothing);
    expect(find.text('203.0.113.10:1081'), findsWidgets);
    expect(find.text('Connect'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('testing unlocated nodes places them in their countries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final service = FakeProxyService(
      probes: {
        '192.0.2.200:1081': const NodeProbe(
          success: true,
          countryCode: 'DE',
          egressIp: '192.0.2.200',
          latencyMs: 140,
        ),
      },
    );
    final state = await _state(tester, service);

    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();
    GalaxyScene scene() =>
        tester.widget<GalaxyCanvas>(find.byType(GalaxyCanvas)).scene;
    final unlocated = scene().systemOf(systemIdFor(''))!.planets.length;
    expect(find.textContaining('have no known location'), findsOneWidget);

    await tester.tap(find.text('Test now'));
    await tester.pumpAndSettle();

    expect(
      scene().systemOf(systemIdFor(''))!.planets,
      hasLength(unlocated - 1),
    );
    expect(
      scene().systemOf(systemIdFor('DE'))!.planets.map((p) => p.node.host),
      contains('192.0.2.200'),
    );
    // Only the two never-tested nodes are probed; the unreachable ones have
    // no egress to find.
    expect(
      service.calls.where((call) => call.startsWith('probe')),
      hasLength(2),
    );
    // Let the summary toast run out.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a country waiting on its probes stops drawing frames', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _WaitingService();
    final state = await _state(tester, service);
    final us = [
      for (final node in state.nodes)
        if (state.effectiveCountry(node) == 'US') node,
    ];

    await tester.pumpWidget(_app(state, selection: systemIdFor('US')));
    await _drawFor(tester, const Duration(seconds: 12));
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.tap(find.text('Test these nodes'));
    // Entering the testing state ripples once, and then nothing moves: any
    // animation would raster the whole window for the full probe timeout.
    await _drawFor(tester, const Duration(seconds: 3));
    expect(us.every(state.isVerifyingNode), isTrue);
    expect(tester.binding.hasScheduledFrame, isFalse);

    service.answer.complete();
    await tester.pumpAndSettle();
    expect(us.any(state.isVerifyingNode), isFalse);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('nodes serving QUIC are marked and can be tested over it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final service = FakeProxyService(
      quicSupport: {'203.0.113.10:1081': const QuicSupport.at(10811)},
      probes: {
        'quic://203.0.113.10:10811': const NodeProbe(
          success: true,
          countryCode: 'US',
          egressIp: '203.0.113.10',
          latencyMs: 60,
        ),
      },
    );
    final state = await _state(tester, service);
    final serving = state.nodes[0];

    await tester.pumpWidget(_app(state, selection: systemIdFor('US')));
    await tester.pumpAndSettle();
    // Asked once, for the whole catalogue, as soon as nodes were shown.
    expect(service.calls.where((call) => call.startsWith('quic ')).length, 1);
    final planets = tester
        .widget<GalaxyCanvas>(find.byType(GalaxyCanvas))
        .scene
        .systemOf(systemIdFor('US'))!
        .planets;
    expect(planets.where((planet) => planet.node.quic).map((p) => p.id), [
      serving.storageKey,
    ]);

    // The choice appears where it means something, and TCP stays the default.
    expect(find.byKey(const Key('test-carrier')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('test-carrier')),
        matching: find.text('QUIC'),
      ),
    );
    await tester.pump();
    service.calls.clear();
    await tester.tap(find.text('Test these nodes'));
    await tester.pumpAndSettle();
    expect(service.calls.where((call) => call.startsWith('probe ')), [
      'probe quic://203.0.113.10:10811',
    ]);
    // The rest were left out, not failed: their TCP results stand.
    expect(find.text('No QUIC'), findsWidgets);
    expect(state.verificationFor(state.nodes[1])?.isVerified, isTrue);
    expect(find.text('QUIC 60 ms'), findsOneWidget);

    await tester.tap(find.text('203.0.113.10:1081'));
    await tester.pumpAndSettle();
    expect(find.text('QUIC · 60 ms'), findsOneWidget);
    expect(find.textContaining('TCP 1081 · QUIC 10811'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a node says when switching restarts TUN, and why it failed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final service = FakeProxyService();
    final state = await _state(tester, service);
    await tester.runAsync(() async {
      expect(await state.start(), isTrue);
      expect(await state.setTunEnabled(true), isTrue);
    });
    // Another host than the current node's, which TUN routes do not exclude.
    final other = state.nodes[0];

    await tester.pumpWidget(_app(state, selection: other.storageKey));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Switching to another host restarts TUN.'),
      findsOneWidget,
    );

    // Where capture follows the new host in place, there is nothing to say,
    // and a refusal is shown in the runtime's own words until retried.
    service.supportsLiveTunSwitch = true;
    service.switchResult = ProxyResult.runtimeError;
    service.switchError = 'QUIC handshake failed: certificate name mismatch';
    await tester.tap(find.byKey(const Key('node-connect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('node-switch-restarts-tun')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('node-switch-error')),
        matching: find.text(service.switchError!),
      ),
      findsOneWidget,
    );

    service.switchResult = ProxyResult.ok;
    await tester.tap(find.byKey(const Key('node-connect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('node-switch-error')), findsNothing);
    expect(state.isCurrentNode(other), isTrue);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _drawFor(WidgetTester tester, Duration duration) async {
  const frame = Duration(microseconds: 16667);
  for (var t = Duration.zero; t < duration; t += frame) {
    await tester.pump(frame);
  }
}

/// Holds every probe until [answer] completes.
class _WaitingService extends FakeProxyService {
  final answer = Completer<void>();

  @override
  Future<NodeProbe> probeNode({
    required String serverHost,
    required int serverPort,
    bool secureTransport = false,
    int timeoutMs = 10000,
  }) async {
    await answer.future;
    return super.probeNode(serverHost: serverHost, serverPort: serverPort);
  }
}
