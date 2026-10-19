// Render the redesigned screens offline with sample data, for review.
// Run with: fvm flutter test tool/render_galaxy_test.dart
// Images land in build/ui-shots/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/providers/theme_provider.dart';
import 'package:proxy_ui/src/screens/home_screen.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_canvas.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_model.dart';
import 'package:proxy_ui/src/services/desktop_settings.dart';
import 'package:proxy_ui/src/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/fake_proxy_service.dart';

Future<void> _loadFonts() async {
  final sdk = Directory('.fvm/flutter_sdk').resolveSymbolicLinksSync();
  final fonts = '$sdk/bin/cache/artifacts/material_fonts';
  ByteData read(String path) =>
      ByteData.sublistView(File(path).readAsBytesSync());
  final roboto = FontLoader('Roboto');
  for (final name in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]) {
    roboto.addFont(Future.value(read('$fonts/$name')));
  }
  await roboto.load();
  await (FontLoader('NotoSansSC')
        ..addFont(Future.value(read('assets/fonts/NotoSansSC-Variable.ttf'))))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(Future.value(read('$fonts/MaterialIcons-Regular.otf')))).load();
}

ThemeData _theme(Brightness brightness) {
  final theme = buildAppTheme(const Color(0xff6750a4), brightness);
  TextTheme withFonts(TextTheme text) => text.apply(
    fontFamily: 'Roboto',
    fontFamilyFallback: const ['NotoSansSC'],
  );
  return theme.copyWith(
    textTheme: withFonts(theme.textTheme),
    primaryTextTheme: withFonts(theme.primaryTextTheme),
  );
}

void main() {
  testWidgets('render the redesigned UI with sample data', (tester) async {
    await tester.runAsync(_loadFonts);
    final catalogue = sampleCatalogue();
    final current = catalogue.nodes[1].addr;
    // This review harness lives outside test/ so the suite does not render
    // images; it still runs under flutter test.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(
      samplePreferences(catalogue, current: current),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
    await AppLanguage.instance.load(systemLocale: const Locale('zh'));

    late ProxyState proxy;
    await tester.runAsync(() async {
      proxy = ProxyState(service: FakeProxyService());
      while (!proxy.isInitialized) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await proxy.start();
    });
    final theme = ThemeState();
    final desktop = DesktopSettings();
    final boundary = GlobalKey();
    var mode = ThemeMode.dark;

    Future<void> show(Size size, ThemeMode themeMode, String language) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      mode = themeMode;
      await AppLanguage.instance.select(language);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: proxy),
              ChangeNotifierProvider.value(value: theme),
              ChangeNotifierProvider.value(value: desktop),
            ],
            child: ListenableBuilder(
              listenable: AppLanguage.instance,
              builder: (context, _) => MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: AppLanguage.instance.locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: _theme(Brightness.light),
                darkTheme: _theme(Brightness.dark),
                themeMode: mode,
                home: HomeScreen(key: ValueKey('$size$themeMode$language')),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> settle([int frames = 50]) async {
      // Let flags and the backdrop rasterise, then run the camera's entrance.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }

    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('build/ui-shots/$name.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    Future<void> openNodes() async {
      await tester.tap(find.text(AppLanguage.instance.strings.nodes).first);
      await settle();
    }

    const wide = Size(1440, 900);
    await show(wide, ThemeMode.dark, 'zh');
    await settle(10);
    await capture('01-dashboard-dark-zh');
    await openNodes();
    await capture('02-galaxy-dark-zh');

    // Select the United States through the canvas's own selection callback.
    await _select(tester, systemIdFor('US'));
    await settle(40);
    await capture('03-galaxy-country-dark-zh');
    await _select(tester, catalogue.nodes[1].storageKey);
    await settle(40);
    await capture('04-galaxy-node-dark-zh');

    await show(wide, ThemeMode.light, 'en');
    await settle(10);
    await openNodes();
    await capture('05-galaxy-light-en');
    await tester.tap(find.text('List'), warnIfMissed: false);
    await settle(5);
    await capture('06-list-light-en');

    await show(const Size(430, 900), ThemeMode.dark, 'zh');
    await settle(10);
    await capture('07-dashboard-phone-dark-zh');
    await openNodes();
    await capture('08-galaxy-phone-dark-zh');

    // The smallest window the desktop app allows.
    await show(const Size(800, 600), ThemeMode.light, 'zh');
    await settle(10);
    await capture('09-dashboard-min-window-light-zh');

    await tester.pumpWidget(const SizedBox());
    proxy.dispose();
    theme.dispose();
    desktop.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// Select a body as a click on it would.
Future<void> _select(WidgetTester tester, String id) async {
  tester.widget<GalaxyCanvas>(find.byType(GalaxyCanvas)).onSelect(id);
  await tester.pump();
}
