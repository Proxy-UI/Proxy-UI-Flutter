/// Fetching a release file and putting it in place, per platform.
///
/// Every step that can be checked is: the manifest's signature before
/// anything is fetched, each file's size and SHA-256 against it, and on macOS
/// the new bundle's Developer ID team and notarization before it replaces the
/// running one. The application quits through its normal path first, so the
/// system proxy, routes and DNS are restored before anything is swapped.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'release_manifest.dart';
import 'native_update_transport.dart';

export 'windows_installer_update.dart';

/// Fetches update files, through the local proxy while it runs: GitHub is
/// often unreachable directly where this app is used.
class UpdateDownloader {
  UpdateDownloader({this.proxyPort, UpdateTransport? transport})
    : transport = transport ?? NativeUpdateTransport.shared;

  final int? proxyPort;
  final UpdateTransport transport;
  UpdateOperation? _active;

  Future<List<int>> bytes(Uri url, {int limit = 1 << 20}) async {
    final result = await transport.start({
      'operation': 'fetch',
      'url': '$url',
      'limit': limit,
      'proxy_port': proxyPort,
    }).result;
    return base64Decode(result['body'] as String);
  }

  Future<void> file(
    Uri url,
    File target, {
    required ReleaseAsset asset,
    required void Function(int received, int total, double speed) onProgress,
  }) async {
    final operation = transport.start(
      {
        'operation': 'download',
        'url': '$url',
        'target': target.path,
        'size': asset.size,
        'sha256': asset.sha256,
        'proxy_port': proxyPort,
      },
      onProgress: (event) => onProgress(
        event['received'] as int,
        event['total'] as int,
        (event['bytes_per_second'] as num).toDouble(),
      ),
    );
    _active = operation;
    try {
      await operation.result;
    } finally {
      _active = null;
    }
  }

  void cancel() => _active?.cancel();
}

bool isCancellation(Object error) => error is UpdateCancelled;

Future<void> _delete(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // A leftover temporary file is not worth failing over.
  }
}

Future<void> verifyChecksum(
  File file,
  ReleaseAsset asset, {
  UpdateTransport? transport,
}) async {
  try {
    await (transport ?? NativeUpdateTransport.shared).start({
      'operation': 'verify',
      'target': file.path,
      'size': asset.size,
      'sha256': asset.sha256,
    }).result;
  } on UpdateException {
    await _delete(file);
    rethrow;
  }
}

Future<ProcessResult> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw UpdateException(
      UpdateFailure.verification,
      '$executable ${arguments.join(' ')}: ${result.stderr}'.trim(),
    );
  }
  return result;
}

/// macOS: the new bundle comes out of the signed, notarized disk image and
/// replaces the running one once the app has quit.
abstract final class MacBundleUpdate {
  /// The Developer ID team every release is signed by.
  static const String teamId = '5T7QB722FM';

  /// The running application bundle.
  static Directory currentBundle() =>
      File(Platform.resolvedExecutable).parent.parent.parent;

  /// Whether the user may replace [bundle] (an app dragged into
  /// /Applications by an administrator usually is; one owned by another user
  /// is not).
  static bool canReplace(Directory bundle) {
    final probe = File(
      '${bundle.parent.path}/.cipherrelay-update-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
      return bundle.statSync().type == FileSystemEntityType.directory;
    } catch (_) {
      return false;
    }
  }

  /// Copy the app out of [image] into [work], once it proves to be this
  /// app's release [build] signed by [teamId] and accepted by Gatekeeper.
  static Future<Directory> stage(
    File image,
    Directory work, {
    required int build,
    required String bundleId,
  }) async {
    final mount = Directory('${work.path}/mount');
    await mount.create(recursive: true);
    await _run('/usr/bin/hdiutil', [
      'attach',
      '-nobrowse',
      '-readonly',
      '-noautoopen',
      '-mountpoint',
      mount.path,
      image.path,
    ]);
    try {
      final apps = mount
          .listSync()
          .whereType<Directory>()
          .where((entry) => entry.path.endsWith('.app'))
          .toList();
      if (apps.length != 1) {
        throw const UpdateException(
          UpdateFailure.verification,
          'The disk image does not hold exactly one application',
        );
      }
      final staged = Directory(
        '${work.path}/${apps.single.uri.pathSegments.where((s) => s.isNotEmpty).last}',
      );
      if (await staged.exists()) await staged.delete(recursive: true);
      await _run('/usr/bin/ditto', [apps.single.path, staged.path]);
      await verifyBundle(staged, build: build, bundleId: bundleId);
      return staged;
    } finally {
      await Process.run('/usr/bin/hdiutil', ['detach', mount.path, '-force']);
    }
  }

  /// Fail unless [app] is intact, signed by [teamId], notarized, and the
  /// release [build] of [bundleId].
  static Future<void> verifyBundle(
    Directory app, {
    required int build,
    required String bundleId,
  }) async {
    await _run('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      app.path,
    ]);
    final details = await _run('/usr/bin/codesign', [
      '-dv',
      '--verbose=2',
      app.path,
    ]);
    if (!'${details.stderr}'.contains('TeamIdentifier=$teamId')) {
      throw const UpdateException(
        UpdateFailure.verification,
        'The application is not signed by the CipherRelay team',
      );
    }
    // Gatekeeper's own verdict: Developer ID signed and notarized.
    await _run('/usr/sbin/spctl', ['--assess', '--type', 'execute', app.path]);
    final plist = '${app.path}/Contents/Info.plist';
    final id = await _run('/usr/bin/plutil', [
      '-extract',
      'CFBundleIdentifier',
      'raw',
      plist,
    ]);
    final version = await _run('/usr/bin/plutil', [
      '-extract',
      'CFBundleVersion',
      'raw',
      plist,
    ]);
    if ('${id.stdout}'.trim() != bundleId ||
        '${version.stdout}'.trim() != '$build') {
      throw UpdateException(
        UpdateFailure.verification,
        'Expected $bundleId build $build, found '
        '${'${id.stdout}'.trim()} build ${'${version.stdout}'.trim()}',
      );
    }
  }

  /// Start a helper that, once process [pid] has exited, swaps [staged] in
  /// for [target] and opens it. If the app never exits the helper gives up
  /// and leaves everything as it was; if the swap fails it puts the old
  /// bundle back.
  static Future<void> handOff(
    Directory staged,
    Directory target,
    int pid, {
    bool reopen = true,
  }) async {
    final script = File('${staged.parent.path}/install-update.sh');
    await script.writeAsString(_macScript);
    await Process.start('/bin/bash', [
      script.path,
      '$pid',
      target.path,
      staged.path,
      reopen ? '1' : '0',
    ], mode: ProcessStartMode.detached);
  }

  static const String _macScript = r'''
#!/bin/bash
pid="$1"; target="$2"; staged="$3"; reopen="$4"
for _ in $(seq 1 600); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.2
done
kill -0 "$pid" 2>/dev/null && exit 1
previous="$target.previous-$$"
if mv "$target" "$previous"; then
  if mv "$staged" "$target"; then
    rm -rf "$previous"
  else
    mv "$previous" "$target"
  fi
fi
[ "$reopen" = 1 ] && open "$target"
rm -f "$0"
''';
}

/// Android: the package goes to the system installer, which asks the user
/// to confirm and refuses one signed with a different certificate.
abstract final class AndroidPackageUpdate {
  static const MethodChannel _channel = MethodChannel('proxy_ui/updates');

  static Future<List<String>> abis() async =>
      (await _channel.invokeListMethod<String>('abis')) ?? const [];

  /// Whether the user has let this app install packages.
  static Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  static Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  static Future<void> install(File package) async {
    try {
      await _channel.invokeMethod<void>('install', {'path': package.path});
    } on PlatformException catch (error) {
      throw UpdateException(UpdateFailure.install, error.message);
    }
  }
}

/// Portable Windows and Linux: the archive is saved to Downloads and shown
/// in the file manager, for the user to unpack where the app lives.
Future<File> saveToDownloads(
  File file,
  Directory downloads,
  String name,
) async {
  await downloads.create(recursive: true);
  final target = File('${downloads.path}${Platform.pathSeparator}$name');
  if (await target.exists()) await target.delete();
  final saved = await file.copy(target.path);
  await _delete(file);
  if (Platform.isWindows) {
    await Process.start('explorer.exe', ['/select,', saved.path]);
  } else if (Platform.isLinux) {
    await Process.start('xdg-open', [downloads.path]);
  } else if (Platform.isMacOS) {
    await Process.start('/usr/bin/open', ['-R', saved.path]);
  }
  return saved;
}
