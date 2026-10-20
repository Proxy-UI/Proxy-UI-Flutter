import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/services/desktop_log_service.dart';

import 'log_backend_fixture.dart';

void main() {
  test('native callbacks are not written a second time', () async {
    final backend = RecordingLogBackend();
    final service = DesktopLogService(
      enabled: true,
      backend: backend,
      directoryProvider: () async => Directory.systemTemp,
    );
    await service.write(LogEntry(level: 2, message: 'native', persisted: true));
    expect(backend.entries, isEmpty);
    expect(backend.directory, isNull);
    await service.write(LogEntry(level: 3, message: 'UI diagnostic'));
    await service.dispose();
    expect(backend.entries.single.message, 'UI diagnostic');
    expect(backend.flushes, 1);
  });

  test('shutdown waits for writes accepted during initialization', () async {
    final gate = Completer<void>();
    final backend = RecordingLogBackend();
    final service = DesktopLogService(
      enabled: true,
      backend: backend,
      directoryProvider: () async {
        await gate.future;
        return Directory.systemTemp;
      },
    );
    final first = service.write(LogEntry(level: 2, message: 'first'));
    final second = service.write(LogEntry(level: 3, message: 'second'));
    final disposed = service.dispose();
    await service.write(LogEntry(level: 2, message: 'after close'));
    expect(backend.flushes, 0);
    gate.complete();
    await Future.wait([first, second, disposed]);
    expect(backend.entries.map((entry) => entry.message), ['first', 'second']);
    expect(backend.flushes, 1);
    expect(identical(service.dispose(), disposed), isTrue);
  });

  test(
    'failed initialization is retryable and does not poison later writes',
    () async {
      final backend = RecordingLogBackend();
      var calls = 0;
      final service = DesktopLogService(
        enabled: true,
        backend: backend,
        directoryProvider: () async {
          if (++calls == 1) throw const FileSystemException('unavailable');
          return Directory.systemTemp;
        },
      );
      await expectLater(
        service.initialize(),
        throwsA(isA<FileSystemException>()),
      );
      await service.write(LogEntry(level: 2, message: 'recovered'));
      await service.dispose();
      expect(backend.entries.single.message, 'recovered');
    },
  );

  test('opens the directory configured for the native writer', () async {
    final backend = RecordingLogBackend();
    String? opened;
    final service = DesktopLogService(
      enabled: true,
      backend: backend,
      directoryProvider: () async => Directory.systemTemp,
      directoryOpener: (path) async => opened = path,
    );
    await service.openLogDirectory();
    expect(opened, backend.directory);
    await service.dispose();
  });
}
