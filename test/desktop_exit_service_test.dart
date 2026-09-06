import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/desktop_exit_service.dart';
import 'package:proxy_ui/src/widgets/app_window_title_bar.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  final windowCalls = <String>[];
  final exitResponses = <String>[];

  setUp(() {
    windowCalls.clear();
    exitResponses.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
          if (call.method == 'isMaximized' || call.method == 'isMinimized') {
            return false;
          }
          windowCalls.add(call.method);
          if (call.method == 'close') {
            // Reproduce Flutter's Windows dispatch order: the engine asks Dart
            // about exit BEFORE window_manager can intercept WM_CLOSE.
            final response = await _sendAppExitRequest();
            exitResponses.add(response);
            if (response == 'exit') await _sendWindowClose();
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  testWidgets('Windows caption close keeps proxy and TUN running repeatedly', (
    tester,
  ) async {
    var proxyRunning = true;
    var tunRunning = true;
    _listen(
      TargetPlatform.windows,
      hideToTray: windowManager.hide,
      prepareToQuit: () async {
        proxyRunning = false;
        tunRunning = false;
      },
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          appBar: AppWindowTitleBar(
            title: 'Proxy',
            useNativeMacControls: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    windowCalls.clear();

    for (var attempt = 0; attempt < 3; attempt++) {
      await tester.tap(find.byKey(const Key('window-close')));
      await tester.pumpAndSettle();
      expect(exitResponses.last, 'cancel');
      expect(proxyRunning, isTrue);
      expect(tunRunning, isTrue);
      await windowManager.show();
    }
    expect(windowCalls, [
      for (var attempt = 0; attempt < 3; attempt++) ...[
        'close',
        'hide',
        'show',
      ],
    ]);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    testWidgets('$platform native window close only hides to tray', (
      tester,
    ) async {
      var quitCalls = 0;
      _listen(
        platform,
        hideToTray: windowManager.hide,
        prepareToQuit: () async => quitCalls++,
      );

      await _sendWindowClose();
      await tester.pump();
      expect(windowCalls, ['hide']);
      expect(quitCalls, 0);
    });
  }

  testWidgets('Windows still cancels exit if hiding the window fails', (
    tester,
  ) async {
    var quitCalls = 0;
    _listen(
      TargetPlatform.windows,
      hideToTray: () async =>
          throw PlatformException(code: 'shell_unavailable'),
      prepareToQuit: () async => quitCalls++,
    );

    expect(await _sendAppExitRequest(), 'cancel');
    expect(quitCalls, 0);
  });

  testWidgets(
    'macOS Quit after closing waits for teardown before allowing exit',
    (tester) async {
      final teardown = Completer<void>();
      final events = <String>[];
      _listen(
        TargetPlatform.macOS,
        hideToTray: windowManager.hide,
        prepareToQuit: () async {
          events.add('stop');
          await teardown.future;
          events.add('flushLogs');
        },
      );

      await _sendWindowClose();
      await tester.pump();
      expect(events, isEmpty);
      expect(windowCalls, ['hide']);

      var replied = false;
      final reply = _sendAppExitRequest().then((response) {
        replied = true;
        return response;
      });
      await tester.pump();
      expect(events, ['stop']);
      expect(replied, isFalse);

      teardown.complete();
      expect(await reply, 'exit');
      expect(events, ['stop', 'flushLogs']);
      expect(windowCalls, ['hide']);
    },
  );
}

void _listen(
  TargetPlatform platform, {
  required AsyncCallback hideToTray,
  required AsyncCallback prepareToQuit,
}) {
  final service = DesktopExitService(
    platform: platform,
    hideToTray: hideToTray,
    prepareToQuit: prepareToQuit,
  );
  WidgetsBinding.instance.addObserver(service);
  windowManager.addListener(service);
  addTearDown(() {
    WidgetsBinding.instance.removeObserver(service);
    windowManager.removeListener(service);
  });
}

Future<String> _sendAppExitRequest() async {
  final reply = Completer<String>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'flutter/platform',
        const JSONMethodCodec().encodeMethodCall(
          const MethodCall('System.requestAppExit', {'type': 'cancelable'}),
        ),
        (data) {
          final response = const JSONMethodCodec().decodeEnvelope(data!);
          reply.complete((response as Map)['response'] as String);
        },
      );
  return reply.future;
}

Future<void> _sendWindowClose() => TestDefaultBinaryMessengerBinding
    .instance
    .defaultBinaryMessenger
    .handlePlatformMessage(
      'window_manager',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onEvent', {'eventName': 'close'}),
      ),
      (_) {},
    );
