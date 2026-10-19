// Check the macOS update path against a real release, on a Mac.
// Run with: fvm flutter test tool/verify_update_install_test.dart
// Downloads the v2.0.5 disk image (about 47 MB) with `gh` into build/.
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/updates/release_manifest.dart';
import 'package:proxy_ui/src/updates/update_installers.dart';

const release = 'v2.0.5';
const image = 'cipherrelay-v2.0.5-64-macos-universal.dmg';

void main() {
  late Directory work;

  setUpAll(() async {
    work = Directory('build/update-check')..createSync(recursive: true);
    for (final name in [image, manifestName]) {
      if (File('${work.path}/$name').existsSync()) continue;
      final result = await Process.run('gh', [
        'release',
        'download',
        release,
        '--repo',
        updateRepository,
        '--pattern',
        name,
        '--dir',
        work.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }
  });

  test(
    'a real release passes every check and stages for replacement',
    () async {
      final manifest = ReleaseManifest.parse(
        File('${work.path}/$manifestName').readAsStringSync(),
      );
      final asset = manifest.assets.firstWhere((a) => a.name == image);
      final copy = File('${work.path}/check-$image');
      await File('${work.path}/$image').copy(copy.path);
      await verifyChecksum(copy, asset);

      final staging = await Directory.systemTemp.createTemp('update-check-');
      addTearDown(() => staging.delete(recursive: true));
      final staged = await MacBundleUpdate.stage(
        copy,
        staging,
        build: manifest.build,
        bundleId: 'com.proxyui.proxyUi',
      );
      expect(
        File('${staged.path}/Contents/MacOS/CipherRelay').existsSync(),
        isTrue,
      );

      // The same release is refused for another app or another build.
      await expectLater(
        MacBundleUpdate.verifyBundle(
          staged,
          build: 65,
          bundleId: 'com.proxyui.proxyUi',
        ),
        throwsA(isA<UpdateException>()),
      );
    },
  );

  test('a locally signed build is not accepted as a release', () async {
    final local = Directory('build/macos/Build/Products/Debug/CipherRelay.app');
    if (!local.existsSync()) return markTestSkipped('No local debug build');
    await expectLater(
      MacBundleUpdate.verifyBundle(
        local,
        build: 64,
        bundleId: 'com.proxyui.proxyUi',
      ),
      throwsA(isA<UpdateException>()),
    );
  });

  test('the helper swaps bundles only after the app exits', () async {
    final root = await Directory.systemTemp.createTemp('update-swap-');
    addTearDown(() => root.delete(recursive: true));
    final target = Directory('${root.path}/CipherRelay.app')..createSync();
    File('${target.path}/marker').writeAsStringSync('old');
    final work = Directory('${root.path}/work')..createSync();
    final staged = Directory('${work.path}/CipherRelay.app')..createSync();
    File('${staged.path}/marker').writeAsStringSync('new');

    final app = await Process.start('/bin/sleep', ['2']);
    await MacBundleUpdate.handOff(staged, target, app.pid, reopen: false);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(File('${target.path}/marker').readAsStringSync(), 'old');

    await app.exitCode;
    for (var i = 0; i < 50 && staged.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(File('${target.path}/marker').readAsStringSync(), 'new');
    expect(staged.existsSync(), isFalse);
    expect(
      root.listSync().map((e) => e.path).where((p) => p.contains('.previous')),
      isEmpty,
    );
  });
}
