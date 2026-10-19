import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/window_state_service.dart';
import 'package:proxy_ui/src/widgets/app_render_activity.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  const channel = MethodChannel('window_manager');
  const platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  });
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  var failHide = false;

  setUp(() async {
    failHide = false;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'isMinimized') return false;
      if (call.method == 'hide' && failHide) {
        throw PlatformException(code: 'hide_failed');
      }
      return null;
    });
    await WindowStateService.instance.show();
  });
  tearDown(() async {
    await WindowStateService.instance.show();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('tray hide mutes rendering even without a native blur event', (
    tester,
  ) async {
    bool? rendering;
    await tester.pumpWidget(
      AppRenderActivity(
        child: Builder(
          builder: (context) {
            rendering = TickerMode.valuesOf(context).enabled;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(rendering, isTrue);
    await WindowStateService.instance.hide();
    await tester.pump();
    expect(rendering, isFalse);

    // A late focus event must not reactivate a window hidden in the tray.
    for (final listener in windowManager.listeners.toList()) {
      listener.onWindowFocus();
    }
    await tester.pump();
    expect(rendering, isFalse);

    await WindowStateService.instance.show();
    await tester.pump();
    expect(rendering, isTrue);
    await tester.pumpWidget(const SizedBox());
  }, variant: platforms);

  testWidgets('failed hide leaves visible content active', (tester) async {
    bool? rendering;
    await tester.pumpWidget(
      AppRenderActivity(
        child: Builder(
          builder: (context) {
            rendering = TickerMode.valuesOf(context).enabled;
            return const SizedBox();
          },
        ),
      ),
    );
    failHide = true;
    await expectLater(
      WindowStateService.instance.hide(),
      throwsA(isA<PlatformException>()),
    );
    await tester.pump();
    expect(rendering, isTrue);
    await tester.pumpWidget(const SizedBox());
  }, variant: platforms);
}
