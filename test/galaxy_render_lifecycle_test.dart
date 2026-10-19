import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/node_health.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_canvas.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_model.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_painter.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_view.dart';
import 'package:proxy_ui/src/widgets/app_render_activity.dart';

GalaxyScene scene({int count = 80, String country = 'US'}) => buildGalaxyScene([
  for (var i = 0; i < count; i++)
    GalaxyNode(
      node: NodeInfo(
        nodeId: 'node-$i',
        addr: '192.0.2.${i + 1}:1081',
        lastSeen: DateTime(2026),
        country: '',
        region: '',
      ),
      country: country,
      health: NodeHealth.fast,
      current: i == 0,
    ),
], connected: true);

final text = GalaxyText(
  home: 'Home',
  unlocated: 'Unknown',
  countryName: (code) => code,
  countryStats: (total, available) => '$available / $total',
);

const desktopPlatforms = TargetPlatformVariant({
  TargetPlatform.windows,
  TargetPlatform.macOS,
  TargetPlatform.linux,
});
const supportedPlatforms = TargetPlatformVariant({
  TargetPlatform.windows,
  TargetPlatform.macOS,
  TargetPlatform.linux,
  TargetPlatform.android,
  TargetPlatform.iOS,
});

Widget app(GalaxyScene scene, {bool enabled = true, bool visible = true}) =>
    MaterialApp(
      home: AppRenderActivity(
        child: TickerMode(
          enabled: enabled,
          child: Scaffold(
            body: visible
                ? GalaxyCanvas(
                    scene: scene,
                    text: text,
                    selected: null,
                    onSelect: (_) {},
                  )
                : const SizedBox(),
          ),
        ),
      ),
    );

GalaxyView viewOf(WidgetTester tester) =>
    (tester.widget<CustomPaint>(find.byKey(const Key('galaxy-canvas'))).painter!
            as GalaxyPainter)
        .view;

Future<void> frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(microseconds: 16667));
  }
}

Future<void> settleGalaxy(WidgetTester tester) async {
  // Exercise the complete finite interaction and camera settling interval.
  await frames(tester, 600);
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets(
    'desktop blur and minimize mute the active galaxy until focus returns',
    (tester) async {
      await tester.pumpWidget(app(scene()));
      await tester.pump();
      final view = viewOf(tester);
      final listeners = windowManager.listeners.toList();
      for (final listener in listeners) {
        listener.onWindowBlur();
      }
      await tester.pump();
      final time = view.time;
      await frames(tester, 120);
      expect(view.time, time);
      expect(tester.binding.transientCallbackCount, 0);
      for (final listener in listeners) {
        listener.onWindowFocus();
      }
      await frames(tester, 5);
      expect(view.time, greaterThan(time));
      for (final listener in listeners) {
        listener.onWindowMinimize();
      }
      await tester.pump();
      final minimizedTime = view.time;
      await frames(tester, 120);
      expect(view.time, minimizedTime);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
    variant: desktopPlatforms,
  );

  testWidgets(
    'a populated connected galaxy rests without scheduling idle frames',
    (tester) async {
      await tester.pumpWidget(app(scene()));
      await settleGalaxy(tester);
      final view = viewOf(tester);
      final time = view.time;
      var repaints = 0;
      view.addListener(() => repaints++);
      await frames(tester, 600);
      expect(view.time, time);
      expect(repaints, 0);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
    variant: supportedPlatforms,
  );

  testWidgets('interaction follows each display frame then returns to rest', (
    tester,
  ) async {
    await tester.pumpWidget(app(scene()));
    await settleGalaxy(tester);
    final view = viewOf(tester);
    await tester.drag(
      find.byKey(const Key('galaxy-canvas')),
      const Offset(90, 35),
    );
    await tester.pump();
    var repaints = 0;
    view.addListener(() => repaints++);
    final before = view.time;
    expect(
      tester.binding.transientCallbackCount,
      1,
      reason: 'An active interaction schedules the next display frame',
    );
    await frames(tester, 120);
    expect(view.time, greaterThan(before));
    expect(repaints, 120);
    await settleGalaxy(tester);
    final restingTime = view.time;
    await frames(tester, 120);
    expect(view.time, restingTime);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'background and detached engines do not tick, resume has no time jump',
    (tester) async {
      await tester.pumpWidget(app(scene()));
      await settleGalaxy(tester);
      final view = viewOf(tester);
      await tester.drag(
        find.byKey(const Key('galaxy-canvas')),
        const Offset(50, 10),
      );
      await frames(tester, 10);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
        final time = view.time;
        await frames(tester, 120);
        expect(view.time, time, reason: '$state must not advance the galaxy');
        expect(tester.binding.transientCallbackCount, 0);
      }
      final time = view.time;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await frames(tester, 2);
      expect(view.time - time, lessThan(0.06));
      await settleGalaxy(tester);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
    variant: supportedPlatforms,
  );

  testWidgets(
    'TickerMode disables a mounted galaxy and page removal disposes it',
    (tester) async {
      final data = scene();
      await tester.pumpWidget(app(data));
      await tester.pump();
      final view = viewOf(tester);
      await tester.pumpWidget(app(data, enabled: false));
      final time = view.time;
      await frames(tester, 120);
      expect(view.time, time);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(app(data, visible: false));
      expect(find.byType(GalaxyCanvas), findsNothing);
      await frames(tester, 120);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'transitions for removed or unpainted nodes expire without a raster frame',
    () {
      final view = GalaxyView();
      addTearDown(view.dispose);
      view.update(scene(count: 1), first: true);
      view.update(scene(count: 2, country: 'JP'), first: false);
      expect(view.busy, isTrue);
      view.update(GalaxyScene.empty, first: false);
      view.time = 3;
      view.expireTransitions();
      expect(view.busy, isFalse);
    },
  );
}
