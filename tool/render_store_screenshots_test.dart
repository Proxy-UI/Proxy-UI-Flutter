// Render actual offline widgets without starting the native application or VPN.
// Run with: fvm flutter test tool/render_store_screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/screens/store_privacy_screen.dart';

void main() {
  testWidgets('render the offline demo for the Mac App Store', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final sdk = Directory('.fvm/flutter_sdk').resolveSymbolicLinksSync();
      final fonts = '$sdk/bin/cache/artifacts/material_fonts';
      final roboto = FontLoader('Roboto');
      for (final name in ['Roboto-Regular.ttf', 'Roboto-Bold.ttf']) {
        roboto.addFont(
          Future.value(
            ByteData.sublistView(File('$fonts/$name').readAsBytesSync()),
          ),
        );
      }
      await roboto.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('$fonts/MaterialIcons-Regular.otf').readAsBytesSync(),
            ),
          ),
        );
      await icons.load();
    });
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
          home: StorePrivacyScreen(onContinue: () async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('build/app-store-screenshots/$name.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.tap(find.text('Explore demo'));
    await tester.pumpAndSettle();
    await capture('01-offline-demo');
    await tester.tap(find.text('Simulate connection'));
    await tester.pumpAndSettle();
    await capture('02-simulated-connection');
    await tester.tap(find.text('Edit sample configuration'));
    await tester.pumpAndSettle();
    await capture('03-sample-configuration');
  });
}
