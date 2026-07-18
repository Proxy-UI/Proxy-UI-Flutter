import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/services/desktop_log_service.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('proxy-ui-logs-');
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('writes entries to files named for their local hour', () async {
    final service = DesktopLogService(
      enabled: true,
      directoryProvider: () async => directory,
      clock: () => DateTime(2026, 7, 19, 14, 30),
    );
    addTearDown(service.dispose);

    await service.write(
      LogEntry(
        level: 2,
        message: 'proxy started',
        timestamp: DateTime(2026, 7, 19, 14, 5, 6, 7),
      ),
    );
    await service.write(
      LogEntry(
        level: 3,
        message: 'next hour',
        timestamp: DateTime(2026, 7, 19, 15, 0),
      ),
    );

    final first = File(
      '${directory.path}${Platform.pathSeparator}proxy-ui-2026-07-19-14.log',
    );
    final second = File(
      '${directory.path}${Platform.pathSeparator}proxy-ui-2026-07-19-15.log',
    );
    expect(await first.readAsString(), contains('[INFO] proxy started'));
    expect(await second.readAsString(), contains('[WARN] next hour'));
  });

  test('removes expired hourly files and leaves other files alone', () async {
    final expired = File(
      '${directory.path}${Platform.pathSeparator}proxy-ui-2026-07-16-13.log',
    );
    final cutoffHour = File(
      '${directory.path}${Platform.pathSeparator}proxy-ui-2026-07-16-14.log',
    );
    final unrelated = File(
      '${directory.path}${Platform.pathSeparator}application.log',
    );
    await expired.writeAsString('expired');
    await cutoffHour.writeAsString('retained');
    await unrelated.writeAsString('unrelated');

    final service = DesktopLogService(
      enabled: true,
      directoryProvider: () async => directory,
      clock: () => DateTime(2026, 7, 19, 14, 30),
    );
    addTearDown(service.dispose);
    await service.initialize();

    expect(await expired.exists(), isFalse);
    expect(await cutoffHour.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
  });

  test('creates and opens the configured log directory', () async {
    String? openedPath;
    final nestedDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}nested',
    );
    final service = DesktopLogService(
      enabled: true,
      directoryProvider: () async => nestedDirectory,
      directoryOpener: (path) async => openedPath = path,
    );
    addTearDown(service.dispose);

    await service.openLogDirectory();

    expect(await nestedDirectory.exists(), isTrue);
    expect(openedPath, nestedDirectory.path);
  });
}
