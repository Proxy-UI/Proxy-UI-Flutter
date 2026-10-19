import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/updates/release_manifest.dart';
import 'package:proxy_ui/src/updates/update_controller.dart';
import 'package:proxy_ui/src/updates/update_dialog.dart';

Map<String, Object> asset(
  String name,
  List<int> bytes, [
  Map<String, Object>? extra,
]) => {
  'name': name,
  'size': bytes.length,
  'sha256': sha256.convert(bytes).toString(),
  ...?extra,
};

ReleaseManifest manifest(int build, List<Map<String, Object>> assets) =>
    ReleaseManifest.parse(
      jsonEncode({
        'version': '2.0.$build',
        'build': '$build',
        'assets': assets,
      }),
    );

void main() {
  test(
    'the shipped public key is the one the release workflow verifies with',
    () {
      final pem = File('scripts/update_signing_key.pub.pem').readAsLinesSync();
      final der = base64Decode(pem.where((l) => !l.startsWith('-----')).join());
      expect(base64Encode(der.sublist(der.length - 32)), updatePublicKey);
    },
  );

  test(
    'a manifest is trusted only with a valid signature of its exact bytes',
    () async {
      final pair = await Ed25519().newKeyPair();
      final public = base64Encode((await pair.extractPublicKey()).bytes);
      final bytes = utf8.encode(
        jsonEncode({'version': '2.0.66', 'build': '66', 'assets': <Object>[]}),
      );
      final signature = base64Encode(
        (await Ed25519().sign(bytes, keyPair: pair)).bytes,
      );
      final release = await verifyReleaseManifest(
        bytes,
        signature,
        publicKey: public,
      );
      expect(release.build, 66);

      final tampered = utf8.encode(utf8.decode(bytes).replaceAll('66', '67'));
      await expectLater(
        verifyReleaseManifest(tampered, signature, publicKey: public),
        throwsA(isA<UpdateException>()),
      );
      // Signed, but not by the release key.
      await expectLater(
        verifyReleaseManifest(bytes, signature),
        throwsA(isA<UpdateException>()),
      );
    },
  );

  test('each installation takes its own file, and Android its own ABI', () {
    final release = manifest(70, [
      asset('cipherrelay-v2.0.70-70-macos-universal.dmg', [1]),
      asset('cipherrelay-v2.0.70-70-windows-x64-setup.exe', [2]),
      asset('cipherrelay-v2.0.70-70-windows-x64.zip', [3]),
      asset('cipherrelay-v2.0.70-70-linux-x64.tar.gz', [4]),
      asset(
        'cipherrelay-v2.0.70-70-android-armeabi-v7a.apk',
        [5],
        {
          'platform': 'android',
          'abis': ['armeabi-v7a'],
          'version_code': 1070,
        },
      ),
      asset(
        'cipherrelay-v2.0.70-70-android-arm64-v8a.apk',
        [6],
        {
          'platform': 'android',
          'abis': ['arm64-v8a'],
          'version_code': 2070,
        },
      ),
    ]);
    UpdatePlan? plan(UpdateHost host) => planUpdate(release, host);

    expect(
      plan(const UpdateHost(os: 'macos', build: 69))!.method,
      UpdateMethod.replaceBundle,
    );
    expect(
      plan(const UpdateHost(os: 'windows', build: 69, windowsInstalled: true))!
          .asset
          .name,
      endsWith('setup.exe'),
    );
    final portable = plan(const UpdateHost(os: 'windows', build: 69))!;
    expect(portable.asset.name, endsWith('x64.zip'));
    expect(portable.method, UpdateMethod.saveDownload);
    expect(
      plan(const UpdateHost(os: 'linux', build: 69))!.method,
      UpdateMethod.saveDownload,
    );

    const phone = UpdateHost(
      os: 'android',
      build: 2069,
      androidAbis: ['arm64-v8a', 'armeabi-v7a'],
    );
    expect(plan(phone)!.asset.versionCode, 2070);
    expect(isNewerRelease(release, phone), isTrue);
    expect(
      isNewerRelease(
        release,
        const UpdateHost(
          os: 'android',
          build: 2070,
          androidAbis: ['arm64-v8a'],
        ),
      ),
      isFalse,
    );
    expect(
      isNewerRelease(release, const UpdateHost(os: 'macos', build: 70)),
      isFalse,
    );

    // Released, but its Android packages are not attached yet.
    final desktopOnly = manifest(71, [
      asset('cipherrelay-v2.0.71-71-macos-universal.dmg', [1]),
    ]);
    expect(isNewerRelease(desktopOnly, phone), isTrue);
    expect(planUpdate(desktopOnly, phone), isNull);
  });

  group('the flow against a release mirror', () {
    late HttpServer server;
    late SimpleKeyPair pair;
    late String public;
    final files = <String, List<int>>{};
    final served = <String>[];

    setUp(() async {
      // The widget test binding answers every request with 400; this group
      // talks to a real local server.
      HttpOverrides.global = null;
      pair = await Ed25519().newKeyPair();
      public = base64Encode((await pair.extractPublicKey()).bytes);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      served.clear();
      server.listen((request) {
        served.add(request.uri.pathSegments.last);
        final body = files[request.uri.pathSegments.last];
        request.response.statusCode = body == null ? 404 : 200;
        if (body != null) request.response.add(body);
        request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Future<void> publish(List<int> manifestBytes) async {
      files[manifestName] = manifestBytes;
      files[signatureName] = utf8.encode(
        base64Encode(
          (await Ed25519().sign(manifestBytes, keyPair: pair)).bytes,
        ),
      );
    }

    UpdateController controller(int build) => UpdateController(
      proxyPort: () => null,
      quit: () async {},
      feed: Uri.parse('http://127.0.0.1:${server.port}/'),
      publicKey: public,
      loadInstalled: () async => InstalledVersion(
        version: '2.0.$build',
        build: build,
        bundleId: 'com.proxyui.proxyUi',
      ),
      loadHost: (installed) async =>
          UpdateHost(os: 'linux', build: installed.build),
    );

    test('checking reports a newer release, or none', () async {
      await publish(
        utf8.encode(
          jsonEncode({
            'version': '2.0.80',
            'build': '80',
            'assets': [
              asset('cipherrelay-v2.0.80-80-linux-x64.tar.gz', [1, 2, 3]),
            ],
          }),
        ),
      );
      final current = controller(80);
      await current.check();
      expect(current.stage, UpdateStage.upToDate);

      final older = controller(79);
      await older.check();
      expect(older.stage, UpdateStage.available);
      expect(older.release!.version, '2.0.80');
      expect(older.plan!.method, UpdateMethod.saveDownload);
    });

    test(
      'a download that differs from the signed manifest is refused',
      () async {
        const name = 'cipherrelay-v2.0.81-81-linux-x64.tar.gz';
        await publish(
          utf8.encode(
            jsonEncode({
              'version': '2.0.81',
              'build': '81',
              'assets': [
                asset(name, [1, 2, 3]),
              ],
            }),
          ),
        );
        files[name] = [9, 9, 9];
        final update = controller(80);
        await update.check();
        expect(update.stage, UpdateStage.available);
        await update.start();
        expect(update.stage, UpdateStage.failed);
        expect(update.failure!.kind, UpdateFailure.checksum);
      },
    );

    test('a manifest signed by another key is never offered', () async {
      final bytes = utf8.encode(
        jsonEncode({'version': '2.0.82', 'build': '82', 'assets': <Object>[]}),
      );
      files[manifestName] = bytes;
      final stranger = await Ed25519().newKeyPair();
      files[signatureName] = utf8.encode(
        base64Encode((await Ed25519().sign(bytes, keyPair: stranger)).bytes),
      );
      final update = controller(80);
      await update.check();
      expect(update.stage, UpdateStage.failed);
      expect(update.failure!.kind, UpdateFailure.signature);
      expect(update.release, isNull);
    });

    testWidgets('the dialog checks once, then downloads only after Update', (
      tester,
    ) async {
      const name = 'cipherrelay-v2.0.83-83-linux-x64.tar.gz';
      final requests = <String>[];
      await tester.runAsync(() async {
        await publish(
          utf8.encode(
            jsonEncode({
              'version': '2.0.83',
              'build': '83',
              'assets': [
                asset(name, [1, 2, 3]),
              ],
            }),
          ),
        );
        files[name] = [7, 7, 7];
      });
      final update = controller(80);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: UpdateDialog(controller: update)),
        ),
      );
      // The check started inside the widget's fake clock: let real I/O
      // happen, then pump so its continuations run.
      Future<void> settleOn(bool Function() done) async {
        for (var i = 0; i < 500 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(done(), isTrue);
      }

      await settleOn(() => update.stage == UpdateStage.available);
      requests.addAll(served);
      expect(find.text('Version 2.0.83 is available'), findsOneWidget);
      expect(requests, [manifestName, signatureName]);

      await tester.tap(find.byKey(const Key('start-update')));
      await settleOn(() => update.stage == UpdateStage.failed);
      expect(served.last, name);
      expect(
        find.text(
          'The download did not match the signed release and was deleted.',
        ),
        findsOneWidget,
      );
      update.dispose();
    });
  });
}
