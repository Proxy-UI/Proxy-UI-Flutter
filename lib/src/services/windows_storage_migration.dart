import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Preserve the original Windows storage identity across display-name changes.
/// Existing directories are never merged: Fake-IP journals assign the same IPs
/// independently and must travel with the preferences from their own generation.
class WindowsStorageMigration {
  static const _files = [
    'shared_preferences.json',
    'tun-virtual-dns-v1.jsonl',
    'proxy-cache.txt',
    'non-proxy-cache.txt',
  ];

  static Future<void> initialize() async {
    if (!Platform.isWindows) return;
    final destination = await getApplicationSupportDirectory();
    await copyIfEmpty(
      source: Directory('${destination.parent.path}/CipherRelay'),
      destination: destination,
    );
  }

  /// Copy a branded-only installation as one unit, publishing it with a rename.
  /// The source remains intact. An existing legacy installation always wins.
  static Future<bool> copyIfEmpty({
    required Directory source,
    required Directory destination,
  }) async {
    if (await destination.exists() && !await destination.list().isEmpty) {
      return false;
    }
    final preferences = File('${source.path}/${_files.first}');
    if (!await preferences.exists()) return false;
    final decoded = jsonDecode(await preferences.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The previous Windows settings are invalid.');
    }
    await destination.parent.create(recursive: true);
    final staging = await destination.parent.createTemp('.proxy-ui-migration-');
    try {
      for (final name in _files) {
        final input = File('${source.path}/$name');
        if (await input.exists()) {
          await input.copy('${staging.path}/$name');
        }
      }
      // A concurrent launch or an existing configuration is never overwritten.
      // Non-recursive deletion succeeds only for an empty placeholder directory.
      if (await destination.exists()) {
        if (!await destination.list().isEmpty) return false;
        await destination.delete();
      }
      await staging.rename(destination.path);
      return true;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }
}
