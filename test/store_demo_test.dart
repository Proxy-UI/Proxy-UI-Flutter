import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/screens/store_demo_screen.dart';
import 'package:proxy_ui/src/screens/store_privacy_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('demo interactions never call VPN or persist sample settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'sentinel': 'unchanged'});
    final calls = <MethodCall>[];
    const channel = MethodChannel('com.proxyui/macos_vpn');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const StoreDemoScreen(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simulate connection'));
    await tester.pumpAndSettle();
    expect(find.text('Simulated connection active'), findsOneWidget);
    expect(find.text('No real traffic is being forwarded.'), findsOneWidget);
    await tester.tap(find.text('Edit sample configuration'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '');
    await tester.tap(find.text('Save sample'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a sample hostname without spaces.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byType(TextFormField),
      'my-demo.example.invalid',
    );
    await tester.tap(find.text('Save sample'));
    await tester.pumpAndSettle();
    expect(find.text('my-demo.example.invalid:1081'), findsOneWidget);
    await tester.tap(find.text('Add sample node'));
    await tester.pumpAndSettle();
    expect(find.text('Sample node 3'), findsOneWidget);
    await tester.tap(find.text('Select').last);
    await tester.pumpAndSettle();
    expect(find.text('node-3.example.invalid:1081'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Remove sample').last);
    await tester.pumpAndSettle();
    expect(find.text('Sample node 3'), findsNothing);
    await tester.tap(find.text('Simulate disconnection'));
    await tester.pumpAndSettle();
    expect(find.text('Demo disconnected'), findsOneWidget);
    expect(calls, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {'sentinel'});
    expect(prefs.getString('sentinel'), 'unchanged');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'demo is available before privacy acknowledgement without services',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var appBuilds = 0;
      await tester.pumpWidget(
        StorePrivacyGate(
          applicationBuilder: () {
            appBuilds++;
            return const SizedBox();
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Explore demo'));
      await tester.pumpAndSettle();
      expect(find.text('Simulate connection'), findsOneWidget);
      expect(appBuilds, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Privacy and your connection'), findsOneWidget);
      expect(appBuilds, 0);
    },
  );
}
