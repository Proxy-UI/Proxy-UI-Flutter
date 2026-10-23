import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/models/proxy_config.dart';
import 'package:proxy_ui/src/models/upstream_endpoint.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/services/desktop_settings.dart';
import 'package:proxy_ui/src/widgets/config_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toastification/toastification.dart';

import 'support/fake_proxy_service.dart';

Future<ProxyState> _state(WidgetTester tester) async {
  late ProxyState state;
  await tester.runAsync(() async {
    state = ProxyState(service: FakeProxyService());
    while (!state.isInitialized) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  addTearDown(state.dispose);
  state.updateConfig(
    ProxyConfigModel(serverHost: 'old.example', setSystemProxy: false),
  );
  return state;
}

Future<void> _open(WidgetTester tester, ProxyState state) async {
  tester.view.physicalSize = const Size(1400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ToastificationWrapper(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: state),
          ChangeNotifierProvider(create: (_) => DesktopSettings()),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: ConfigDialog()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Set<UpstreamTransport> _carrier(WidgetTester tester) => tester
    .widget<SegmentedButton<UpstreamTransport>>(
      find.byKey(const Key('server-transport')),
    )
    .selected;

String _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a pasted QUIC address fills the carrier, host and port', (
    tester,
  ) async {
    final state = await _state(tester);
    await _open(tester, state);
    expect(_carrier(tester), {UpstreamTransport.tcp});
    expect(find.byKey(const Key('quic-help')), findsNothing);
    expect(find.text('Server Port'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('server-host')),
      'quic://node.example:10811',
    );
    await tester.pump();
    expect(_carrier(tester), {UpstreamTransport.quic});
    expect(_field(tester, 'server-host'), 'node.example');
    expect(_field(tester, 'server-port'), '10811');
    expect(find.text('Server port (UDP)'), findsOneWidget);
    expect(find.byKey(const Key('quic-help')), findsOneWidget);
    // Nothing is running, so applying only saves and says nothing about it.
    expect(find.byKey(const Key('apply-impact')), findsNothing);

    await tester.tap(find.text('Apply configuration'));
    await tester.pumpAndSettle();
    expect(state.config.serverHost, 'quic://node.example');
    expect(state.config.serverPort, 10811);
    // Let the confirmation toasts run out.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('choosing TCP again keeps the host and port as typed', (
    tester,
  ) async {
    final state = await _state(tester);
    state.updateConfig(
      state.config.copyWith(serverHost: 'quic://node.example', serverPort: 1),
    );
    await _open(tester, state);
    expect(_carrier(tester), {UpstreamTransport.quic});
    expect(_field(tester, 'server-host'), 'node.example');

    await tester.tap(find.text('TCP'));
    await tester.pump();
    expect(_carrier(tester), {UpstreamTransport.tcp});
    await tester.tap(find.text('Apply configuration'));
    await tester.pumpAndSettle();
    expect(state.config.serverHost, 'node.example');
    expect(state.config.serverPort, 1);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('while connected, the dialog says what Apply will do', (
    tester,
  ) async {
    final state = await _state(tester);
    await tester.runAsync(state.start);
    await _open(tester, state);
    expect(find.byKey(const Key('apply-impact')), findsNothing);

    await tester.enterText(find.byKey(const Key('server-port')), '1082');
    await tester.pump();
    expect(
      find.text('Open connections stay on the current server.'),
      findsOneWidget,
    );

    await tester.tap(find.text('QUIC'));
    await tester.pump();
    expect(
      find.text('Open connections stay on the current server.'),
      findsOneWidget,
    );

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pump();
    expect(find.text('Applying reconnects the proxy.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
