import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/flag_atlas.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_backdrop.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_painter.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/planet_atlas.dart';
import 'package:proxy_ui/src/widgets/planet_glyph.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('planet sprites are reused and released on background or theme '
      'change', () {
    final atlas = PlanetAtlas();
    addTearDown(atlas.dispose);
    atlas.palette(ColorScheme.fromSeed(seedColor: Colors.indigo));
    void frame() {
      final recorder = ui.PictureRecorder();
      atlas.begin(Canvas(recorder), ratio: 2);
      paintSphere(atlas, const Offset(20, 20), 8, Colors.green, dark: true);
      atlas.end();
      recorder.endRecording().dispose();
    }

    // A background canvas paints vectors and creates no image.
    frame();
    expect(atlas.debugImage, isNull);
    atlas.enabled = true;
    frame();
    final image = atlas.debugImage;
    expect(image, isNotNull);
    frame();
    expect(atlas.debugImage, same(image));
    atlas.enabled = false;
    expect(image!.debugDisposed, isTrue);
    expect(atlas.debugImage, isNull);
    atlas.enabled = true;
    frame();
    final themed = atlas.debugImage!;
    atlas.palette(ColorScheme.fromSeed(seedColor: Colors.red));
    expect(themed.debugDisposed, isTrue);
    expect(PlanetAtlas.liveBytes, 0);
  });

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
