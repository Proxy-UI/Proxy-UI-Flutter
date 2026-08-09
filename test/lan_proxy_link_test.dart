import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/local_network_service.dart';
import 'package:proxy_ui/src/widgets/lan_proxy_link.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toastification/toastification.dart';

class _FakeInterface implements NetworkInterface {
  _FakeInterface(this.name, List<String> addresses)
    : addresses = <InternetAddress>[
        for (final address in addresses) InternetAddress(address),
      ];

  @override
  final String name;

  @override
  final List<InternetAddress> addresses;

  @override
  int get index => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The widget reads a remembered choice before it can show anything, and
  // without a backing store that read never answers.
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('shows and copies the current LAN HTTP proxy link', (
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
                interfaceLookup: () async => [
                  _FakeInterface('WLAN', ['192.168.21.33']),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('http://192.168.21.33:1080'), findsOneWidget);
    expect(find.byKey(const Key('lan-proxy-picker')), findsNothing);
    await tester.tap(find.byTooltip('Copy LAN proxy link'));
    await tester.pump();

    expect(copiedText, 'http://192.168.21.33:1080');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('lets the user switch to the other live network', (tester) async {
    await tester.pumpWidget(
      ToastificationWrapper(
        child: MaterialApp(
          home: Scaffold(
            body: LanProxyLink(
              port: 1080,
              networkService: LocalNetworkService(
                interfaceLookup: () async => [
                  _FakeInterface('WLAN', ['192.168.21.5']),
                  _FakeInterface('以太网 2', ['192.168.255.10']),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing in `dart:io` says which adapter carries traffic, so the first
    // guess has to be correctable rather than final.
    expect(find.text('http://192.168.21.5:1080'), findsOneWidget);
    expect(find.text('LAN HTTP proxy · WLAN'), findsOneWidget);

    await tester.tap(find.byKey(const Key('lan-proxy-picker')));
    await tester.pumpAndSettle();
    // Tapping the label itself lands on the item's checkmark gutter, so drive
    // the menu entry that owns it.
    await tester.tap(
      find.ancestor(
        of: find.text('192.168.255.10 · 以太网 2'),
        matching: find.byType(CheckedPopupMenuItem<LanAddress>),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('http://192.168.255.10:1080'), findsOneWidget);
    expect(find.text('LAN HTTP proxy · 以太网 2'), findsOneWidget);
  });
}
