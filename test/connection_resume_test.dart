import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_proxy_service.dart';

class _SurvivingService extends FakeProxyService {
  bool running = false;
  bool capturing = false;
  @override
  bool get isRunning => running;
  @override
  bool get isTunRunning => capturing;
}

Future<void> initialized(ProxyState state) async {
  for (var i = 0; i < 200 && !state.isInitialized; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(state.isInitialized, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'initial state adopts a surviving native listener and capture',
    () async {
      final service = _SurvivingService()
        ..running = true
        ..capturing = true;
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await initialized(state);
      expect(state.isRunning, isTrue);
      expect(state.isTunRunning, isTrue);
      expect(service.calls, isEmpty);
    },
  );

  test(
    'resume reconciles a stale disconnected snapshot without restarting VPN',
    () async {
      final service = _SurvivingService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await initialized(state);
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      service.running = service.capturing = true;
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(state.isRunning, isTrue);
      expect(state.isTunRunning, isTrue);
      expect(service.calls, isEmpty);
    },
  );

  test(
    'connect on a stale snapshot recovers state instead of rebinding the port',
    () async {
      final service = _SurvivingService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await initialized(state);
      service.running = service.capturing = true;
      expect(await state.start(), isTrue);
      expect(state.isRunning, isTrue);
      expect(state.isTunRunning, isTrue);
      expect(service.calls, isEmpty);
    },
  );
}
