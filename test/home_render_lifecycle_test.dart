import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/providers/theme_provider.dart';
import 'package:proxy_ui/src/screens/home_screen.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_canvas.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_painter.dart';
import 'package:proxy_ui/src/services/desktop_settings.dart';
import 'package:proxy_ui/src/widgets/app_render_activity.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_proxy_service.dart';

void main() {
  testWidgets(
    'phone home is lazy, connected dashboard settles, leaving the map stops its frames',
    (tester) async {
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final catalogue = sampleCatalogue();
      SharedPreferences.setMockInitialValues(
        samplePreferences(catalogue, current: catalogue.nodes.first.addr),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => call.method == 'isMaximized' ? false : null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('window_manager'),
              null,
            ),
      );
      late ProxyState state;
      await tester.runAsync(() async {
        state = ProxyState(service: FakeProxyService());
        while (!state.isInitialized) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await state.start();
      });
      final theme = ThemeState();
      final settings = DesktopSettings();
      addTearDown(state.dispose);
      addTearDown(theme.dispose);
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: state),
            ChangeNotifierProvider.value(value: theme),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AppRenderActivity(child: HomeScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 40));
      expect(find.byType(GalaxyCanvas), findsNothing);
      expect(find.text('Connected'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 20));
      expect(tester.binding.hasScheduledFrame, isFalse);

      await tester.tap(find.byKey(const Key('open-node-map')));
      await tester.pumpAndSettle(const Duration(milliseconds: 40));
      expect(find.byType(GalaxyCanvas), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      GalaxyPainter painter() =>
          tester
                  .widget<CustomPaint>(find.byKey(const Key('galaxy-canvas')))
                  .painter!
              as GalaxyPainter;
      final previous = painter();
      var paints = 0;
      previous.view.addListener(() => paints++);
      // A settings notification and live log updates must not invalidate the
      // map when its nodes, theme and language have not changed.
      state.updateConfig(
        state.config.copyWith(allowLan: !state.config.allowLan),
      );
      state.logRevision.value++;
      await tester.pump();
      expect(painter().shouldRepaint(previous), isFalse);
      expect(paints, 0);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.tap(find.text('Logs').last);
      await tester.pumpAndSettle(const Duration(milliseconds: 40));
      expect(find.byType(GalaxyCanvas), findsNothing);
      await tester.pump(const Duration(seconds: 20));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
