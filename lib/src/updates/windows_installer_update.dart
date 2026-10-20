import 'dart:convert';
import 'dart:io';

import 'release_manifest.dart';

class WindowsUpdateHandoff {
  WindowsUpdateHandoff._(this.directory);
  final Directory directory;
  Future<void> cancel() =>
      File('${directory.path}/cancel').writeAsString('cancelled', flush: true);
}

abstract final class WindowsInstallerUpdate {
  static bool isInstalled() =>
      File('${File(Platform.resolvedExecutable).parent.path}/unins000.exe')
          .existsSync();

  static Future<WindowsUpdateHandoff> handOff(
    File installer,
    int processId, {
    required String version,
    required int build,
    required String sha256,
    required int size,
  }) async {
    final work = installer.absolute.parent;
    final handoff = WindowsUpdateHandoff._(work);
    final request = File('${work.path}/install-request.json');
    final helper =
        '${File(Platform.resolvedExecutable).parent.path}/cipherrelay-updater.exe';
    await request.writeAsString(
      jsonEncode({
        'processId': processId,
        'installer': installer.absolute.path,
        'app': Platform.resolvedExecutable,
        'version': '$version+$build',
        'sha256': sha256,
        'size': size,
      }),
      flush: true,
    );
    try {
      // Rust resolves elevation, pins the outgoing process and acknowledges
      // readiness before returning. No detached shell participates.
      final result = await Process.run(helper, ['--prepare', request.path]);
      if (result.exitCode != 0) {
        final status = File('${work.path}/install-status.json');
        final detail = await status.exists()
            ? (jsonDecode(await status.readAsString())
                  as Map<String, dynamic>)['message']
            : result.stderr;
        throw StateError('$detail');
      }
      return handoff;
    } catch (error) {
      await handoff.cancel();
      throw UpdateException(
        UpdateFailure.install,
        '$error (update logs: ${work.path})',
      );
    }
  }
}
