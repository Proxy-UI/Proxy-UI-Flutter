import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/tray_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'tray teardown keeps the window reachable during and after hiding',
    () async {
      const channel = MethodChannel('window_manager');
      final calls = <String>[];
      final hide = Completer<void>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'hide') await hide.future;
        if (call.method == 'isMinimized' || call.method == 'isVisible') {
          return true;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final tray = TrayService.instance;
      expect(tray.needsExitRetry, isFalse);
      final hiding = tray.hideWindow();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['hide']);
      tray.dispose();
      expect(tray.needsExitRetry, isTrue);
      hide.complete();
      await hiding;
      expect(calls, containsAllInOrder(['hide', 'restore', 'show', 'focus']));
      calls.clear();
      await tray.hideWindow();
      expect(calls, isNot(contains('hide')));
      expect(calls, containsAllInOrder(['restore', 'show', 'focus']));
    },
  );
}
