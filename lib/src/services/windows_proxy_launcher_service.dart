import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'proxy_launcher_service.dart';

/// PowerShell supplies Windows' file picker, shell shortcuts and Recycle Bin.
/// User values travel as JSON on stdin, never as interpolated shell commands.
class WindowsProxyLauncherService extends ProxyLauncherService {
  @override
  Future<Object?> invokePlatform(
    String action, [
    Map<String, Object>? input,
  ]) async {
    final support = await getApplicationSupportDirectory();
    final tools = Directory('${support.path}\\ProxyLauncherTools');
    await tools.create(recursive: true);
    for (final name in ['manage.ps1', 'runtime.ps1', 'applications.ps1']) {
      final source = await rootBundle.loadString(
        'assets/launchers/windows/$name',
      );
      final file = File('${tools.path}\\$name');
      final content =
          '\ufeff$source'; // Windows PowerShell 5.1 reads UTF-8 via BOM.
      if (!await file.exists() || await file.readAsString() != content) {
        await file.writeAsString(content, flush: true);
      }
    }
    final systemRoot = Platform.environment['SystemRoot'];
    if (systemRoot == null) throw StateError('SystemRoot is unavailable.');
    final process = await Process.start(
      '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-STA',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        '${tools.path}\\manage.ps1',
        '-Action',
        action == 'chooseApplication'
            ? 'Choose'
            : '${action[0].toUpperCase()}${action.substring(1)}',
      ],
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    process.stdin.add(utf8.encode(jsonEncode(input ?? {})));
    await process.stdin.close();
    final output = await stdout;
    final error = await stderr;
    if (await process.exitCode != 0) {
      throw PlatformException(code: 'launcher_error', message: error.trim());
    }
    return output.trim().isEmpty ? null : jsonDecode(output);
  }
}
