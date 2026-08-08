import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/local_network_service.dart';
import 'package:proxy_ui/src/widgets/lan_proxy_link.dart';
import 'package:toastification/toastification.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows and copies the current Wi-Fi HTTP proxy link', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<Object?, Object?>)['text'] as String;
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
        child: MaterialApp(
          home: Scaffold(
            body: LanProxyLink(
              port: 1080,
              networkService: LocalNetworkService(
                wifiAddressLookup: () async => '192.168.21.33',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('http://192.168.21.33:1080'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy LAN proxy link'));
    await tester.pump();

    expect(copiedText, 'http://192.168.21.33:1080');
    await tester.pump(const Duration(seconds: 3));
  });
}
