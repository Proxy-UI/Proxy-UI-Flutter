import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/widgets/app_window_title_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'isMaximized') return false;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'desktop title bar combines brand, actions, and caption controls',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            appBar: AppWindowTitleBar(
              title: 'Proxy With Flutter',
              useNativeMacControls: false,
              actions: [Icon(Icons.settings, key: Key('title-action'))],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Proxy With Flutter'), findsOneWidget);
      expect(find.byKey(const Key('title-action')), findsOneWidget);
      expect(find.byKey(const Key('window-minimize')), findsOneWidget);
      expect(find.byKey(const Key('window-maximize')), findsOneWidget);
      expect(find.byKey(const Key('window-close')), findsOneWidget);
      final closeRect = tester.getRect(find.byKey(const Key('window-close')));
      expect(closeRect.width, 46);
      expect(closeRect.height, AppWindowTitleBar.height);
      expect(
        closeRect.right,
        tester.view.physicalSize.width / tester.view.devicePixelRatio,
      );
      expect(
        tester.getSize(find.byType(AppWindowTitleBar)).height,
        AppWindowTitleBar.height,
      );
    },
  );

  testWidgets(
    'macOS layout reserves native controls without duplicating them',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            appBar: AppWindowTitleBar(
              title: 'Proxy With Flutter',
              useNativeMacControls: true,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Proxy With Flutter'), findsOneWidget);
      expect(find.byKey(const Key('window-minimize')), findsNothing);
      expect(find.byKey(const Key('window-maximize')), findsNothing);
      expect(find.byKey(const Key('window-close')), findsNothing);
    },
  );
}
