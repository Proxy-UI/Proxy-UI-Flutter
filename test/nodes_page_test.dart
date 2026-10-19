import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
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

Widget _app(ProxyState state) => ToastificationWrapper(
  child: ChangeNotifierProvider.value(
    value: state,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildAppTheme(Colors.indigo, Brightness.dark),
      home: const Scaffold(body: NodesPage()),
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
}
