import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/flag_atlas.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_backdrop.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_painter.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/planet_atlas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'planet textures are reused and released on background or theme change',
    (tester) async {
      final atlas = PlanetAtlas();
      addTearDown(atlas.dispose);
      final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
      atlas.palette(scheme);
      var ready = 0;
      void loaded() => ready++;
      expect(atlas.imageFor(Colors.green, true, loaded), isNull);
      atlas.enabled = true;
      await tester.runAsync(() async {
        atlas.imageFor(Colors.green, true, loaded);
        for (var i = 0; i < 200 && ready == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      final image = atlas.imageFor(Colors.green, true, loaded);
      expect(image, isNotNull);
      expect(atlas.imageFor(Colors.green, true, loaded), same(image));
      atlas.enabled = false;
      expect(image!.debugDisposed, isTrue);
      expect(atlas.imageFor(Colors.green, true, loaded), isNull);
      atlas.enabled = true;
      await tester.runAsync(() async {
        atlas.imageFor(Colors.green, true, loaded);
        // A theme change invalidates even an in-flight rasterization.
        atlas.palette(ColorScheme.fromSeed(seedColor: Colors.red));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(ready, 1);
    },
  );

  test('different visible canvases keep independent backdrop caches', () {
    final dashboard = BackdropCache();
    final catalogue = BackdropCache();
    addTearDown(dashboard.dispose);
    addTearDown(catalogue.dispose);
    final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
    void ready() {}
    final first = dashboard.of(const Size(900, 600), scheme, 1, ready);
    catalogue.of(const Size(1200, 800), scheme, 2, ready);
    expect(dashboard.of(const Size(900, 600), scheme, 1, ready), same(first));
    catalogue.dispose();
    expect(dashboard.of(const Size(900, 600), scheme, 1, ready), same(first));
    dashboard.dispose();
    expect(
      dashboard.of(const Size(900, 600), scheme, 1, ready),
      isNot(same(first)),
    );
    dashboard.enabled = false;
    expect(dashboard.of(const Size(900, 600), scheme, 1, ready), isNull);
  });

  test(
    'labels keep current layouts and dispose obsolete native paragraphs',
    () {
      final labels = LabelCache();
      addTearDown(labels.dispose);
      labels.beginFrame();
      final old = labels.of('old', () => const TextSpan(text: 'Old'));
      final current = labels.of(
        'current',
        () => const TextSpan(text: 'Current'),
      );
      labels.endFrame();
      labels.beginFrame();
      expect(
        labels.of('current', () => throw StateError('relaid out')),
        same(current),
      );
      labels.endFrame();
      expect(old.debugDisposed, isTrue);
      expect(current.debugDisposed, isFalse);
      labels.dispose();
      expect(current.debugDisposed, isTrue);
    },
  );

  testWidgets(
    'flags load only for visible canvases and release the final image',
    (tester) async {
      final atlas = FlagAtlas.instance;
      var ready = 0;
      void listener() => ready++;
      void second() {}
      expect(atlas.imageFor('US'), isNull);
      atlas.addListener(listener);
      atlas.addListener(second);
      addTearDown(() {
        atlas.removeListener(listener);
        atlas.removeListener(second);
      });
      await tester.runAsync(() async {
        atlas.imageFor('US');
        for (var i = 0; i < 200 && ready == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      final image = atlas.imageFor('US');
      expect(image, isNotNull);
      atlas.removeListener(listener);
      expect(atlas.imageFor('US'), same(image));
      atlas.removeListener(second);
      expect(image!.debugDisposed, isTrue);
      expect(atlas.imageFor('US'), isNull);
    },
  );
}
