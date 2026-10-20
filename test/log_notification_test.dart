import 'dart:io';

import 'log_backend_fixture.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/services/desktop_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The cost of log streaming is invisible from the UI, so it needs pinning:
/// nothing here changes what the user sees, and a well-meaning change could
/// silently put every screen back on a ten-per-second rebuild.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'ERROR view still persists INFO diagnostics and keeps the native floor',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'proxy-view-log-',
      );
      final backend = RecordingLogBackend();
      final disk = DesktopLogService(
        backend: backend,
        enabled: true,
        directoryProvider: () async => directory,
      );
      final service = _SilentProxyService();
      final state = ProxyState(service: service, desktopLogService: disk);
      await _waitUntilInitialized(state);
      state.setMinLogLevel(4);
      expect(service.nativeLevel, 2);
      ProxyService.debugEmitLog(
        LogEntry(level: 2, message: 'bypassing UDP game.exe via physical NIC'),
      );
      ProxyService.debugEmitLog(
        LogEntry(level: 4, message: 'failed destination example.test:443'),
      );
      await _settle();
      expect(state.filteredLogs.map((entry) => entry.level), [4]);
      state.dispose();
      await disk.dispose();
      final text = backend.entries.map((entry) => entry.message).join('\n');
      expect(text, contains('bypassing UDP game.exe via physical NIC'));
      expect(text, contains('failed destination example.test:443'));
      await directory.delete(recursive: true);
    },
  );

  test('log arrivals notify only the log channel, and coalesce', () async {
    final state = ProxyState(
      service: _SilentProxyService(),
      // Disk persistence is a separate concern and needs path_provider.
      desktopLogService: DesktopLogService(enabled: false),
    );
    addTearDown(state.dispose);
    await _waitUntilInitialized(state);

    var providerNotifications = 0;
    var logNotifications = 0;
    state.addListener(() => providerNotifications++);
    state.logRevision.addListener(() => logNotifications++);

    for (var i = 0; i < 50; i++) {
      ProxyService.debugEmitLog(LogEntry(level: 2, message: 'line $i'));
    }
    await _settle();

    expect(state.logCount, 50);
    expect(
      logNotifications,
      1,
      reason: 'a burst has to coalesce into a single revision bump',
    );
    expect(
      providerNotifications,
      0,
      reason: 'screens that display no logs must not rebuild for log lines',
    );
  });

  test(
    'filtered logs are cached until the buffer or threshold changes',
    () async {
      final state = ProxyState(
        service: _SilentProxyService(),
        // Disk persistence is a separate concern and needs path_provider.
        desktopLogService: DesktopLogService(enabled: false),
      );
      addTearDown(state.dispose);
      await _waitUntilInitialized(state);

      ProxyService.debugEmitLog(LogEntry(level: 4, message: 'boom'));
      await _settle();

      final first = state.filteredLogs;
      expect(
        identical(state.filteredLogs, first),
        isTrue,
        reason: 'repeated reads within a frame must not re-filter',
      );

      ProxyService.debugEmitLog(LogEntry(level: 4, message: 'again'));
      await _settle();
      expect(
        identical(state.filteredLogs, first),
        isFalse,
        reason: 'a new entry has to invalidate the cache',
      );

      final second = state.filteredLogs;
      state.setMinLogLevel(0);
      expect(
        identical(state.filteredLogs, second),
        isFalse,
        reason: 'a threshold change has to invalidate the cache',
      );
    },
  );

  test('the threshold decides which entries survive filtering', () async {
    final state = ProxyState(
      service: _SilentProxyService(),
      // Disk persistence is a separate concern and needs path_provider.
      desktopLogService: DesktopLogService(enabled: false),
    );
    addTearDown(state.dispose);
    await _waitUntilInitialized(state);

    state.setMinLogLevel(3);
    for (final level in [0, 2, 3, 4]) {
      ProxyService.debugEmitLog(LogEntry(level: level, message: 'l$level'));
    }
    await _settle();

    expect(state.logCount, 4, reason: 'the buffer keeps everything');
    expect(state.filteredLogs.map((e) => e.level), [
      3,
      4,
    ], reason: 'the view shows the threshold and above');
  });
}

Future<void> _waitUntilInitialized(ProxyState state) async {
  for (var attempt = 0; attempt < 50 && !state.isInitialized; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(state.isInitialized, isTrue);
}

/// Long enough for the 100 ms log notification window to close.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

/// Keeps `ProxyState` away from the native library, and reports "not running"
/// so log arrivals never trip the connection reconciliation that legitimately
/// does notify listeners.
class _SilentProxyService extends ProxyService {
  int? nativeLevel;
  @override
  void initLogging() {}

  @override
  void setLogLevel(int level) {
    nativeLevel = level;
  }

  @override
  bool restoreOrphanedSystemProxy() => false;

  @override
  bool get isRunning => false;

  @override
  bool get isTunRunning => false;

  @override
  void dispose() {}
}
