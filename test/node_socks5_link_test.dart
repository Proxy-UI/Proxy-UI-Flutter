import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/models/socks5_link.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/screens/nodes/node_socks5_link.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toastification/toastification.dart';

import 'support/fake_proxy_service.dart';

void main() {
  setUp(() {
    final catalogue = sampleCatalogue();
    SharedPreferences.setMockInitialValues(samplePreferences(catalogue));
  });

  testWidgets('a node serving SOCKS5 shows a copyable link and others none', (
    tester,
  ) async {
    final nodes = sampleCatalogue().nodes;
    final serving = nodes[0];
    final url = 'socks5://cipherrelay:secret-value@${serving.host}:1080';
    final service = FakeProxyService(
      socks5Links: {
        serving.addr: Socks5Link(
          url: url,
          username: 'cipherrelay',
          host: serving.host,
          port: 1080,
          udp: true,
        ),
      },
    );
    late ProxyState state;
    await tester.runAsync(() async {
      state = ProxyState(service: service);
      while (!state.isInitialized) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    addTearDown(state.dispose);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      ToastificationWrapper(
        child: ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: [
                  NodeSocks5Link(node: serving),
                  NodeSocks5Link(node: nodes[1]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      service.calls,
      containsAll(['socks5 ${serving.addr}', 'socks5 ${nodes[1].addr}']),
    );
    expect(find.byKey(const Key('node-socks5-link')), findsOneWidget);
    expect(find.text('SOCKS5 link · TCP and UDP'), findsOneWidget);
    expect(
      find.text('socks5://cipherrelay:••••••@${serving.host}:1080'),
      findsOneWidget,
    );
    expect(find.textContaining('secret-value'), findsNothing);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(find.text(url), findsOneWidget);

    await tester.tap(find.byTooltip('Copy SOCKS5 link'));
    await tester.pump();
    expect(copied, url);
    // Let the confirmation toast run out.
    await tester.pump(const Duration(seconds: 4));
  });
}
