import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/screens/proxy_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/macos_store_proxy_service.dart';
import 'package:proxy_ui/src/ffi/proxy_ffi.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/models/proxy_config.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/services/build_capabilities.dart';
import 'package:proxy_ui/src/services/macos_vpn_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const methods = MethodChannel('com.proxyui/macos_vpn');
const events = MethodChannel('com.proxyui/macos_vpn/events');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  var connected = false;
  var failStart = false;
  Completer<void>? pendingStart;

  setUp(() {
    calls = [];
    connected = false;
    failStart = false;
    pendingStart = null;
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'start') {
        if (pendingStart != null) await pendingStart!.future;
        if (failStart) {
          failStart = false;
          throw PlatformException(
            code: 'vpn_error',
            message: 'VPN permission was denied',
          );
        }
        connected = true;
      } else if (call.method == 'stop') {
        connected = false;
      }
      return {'running': connected, 'error': null};
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  testWidgets('store VPN page hides helper diagnostics and process controls', (
    tester,
  ) async {
    late ProxyState state;
    await tester.runAsync(() async {
      state = ProxyState(service: _QuietStoreService());
      await waitForState(state);
    });
    addTearDown(state.dispose);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [1200.0, 440.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ProxyPage(scaffoldKey: GlobalKey<ScaffoldState>()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('VPN Service'), findsOneWidget);
      expect(find.byIcon(Icons.security_outlined), findsNothing);
      expect(find.byIcon(Icons.help_outline), findsNothing);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.textContaining('Android'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  }, skip: !BuildCapabilities.isMacAppStore);

  test(
    'waits for system connection and sends only provider configuration',
    () async {
      final service = MacosStoreProxyService();
      addTearDown(service.dispose);
      await service.initializePlatform();
      pendingStart = Completer<void>();
      final starting = service.start(
        serverHost: 'node.example',
        serverPort: 1081,
        localPort: 18081,
        setSystemProxy: true,
        allowLan: true,
        tunBypassProcesses: ['browser'],
      );
      await Future<void>.delayed(Duration.zero);
      expect(service.isRunning, isFalse);
      final config = calls.last.arguments as Map;
      expect(config['serverHost'], 'node.example');
      expect(config['autoProxy'], isFalse);
      expect(config['reverseGeo'], isFalse);
      expect(config.containsKey('setSystemProxy'), isFalse);
      expect(config.containsKey('allowLan'), isFalse);
      expect(config.containsKey('tunBypassProcesses'), isFalse);
      pendingStart!.complete();
      expect(await starting, ProxyResult.ok);
      expect(service.isTunRunning, isTrue);
      expect(await service.stop(), ProxyResult.ok);
      expect(service.isRunning, isFalse);
      expect(service.restoreOrphanedSystemProxy(), isFalse);
      expect(
        service.switchUpstream(serverHost: 'other.example', serverPort: 1),
        ProxyResult.invalidParam,
      );
    },
  );

  test(
    'reports system denial instead of a successful local listener',
    () async {
      final service = MacosStoreProxyService();
      addTearDown(service.dispose);
      await service.initializePlatform();
      failStart = true;
      expect(
        await service.start(serverHost: 'node.example', serverPort: 1081),
        ProxyResult.runtimeError,
      );
      expect(service.isRunning, isFalse);
      expect(service.lastError, 'VPN permission was denied');
    },
  );

  test(
    'restores the existing connection and follows an external disconnect',
    () async {
      connected = true;
      final vpn = MacosVpnService();
      addTearDown(vpn.dispose);
      await vpn.initialize();
      expect(vpn.running, isTrue);
      final changed = vpn.changes.first;
      messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'running': false,
          'error': 'Network connection lost',
        }),
        (_) {},
      );
      await changed;
      expect(vpn.running, isFalse);
      expect(vpn.lastError, 'Network connection lost');
    },
  );

  test(
    'store node failure restores prior VPN and config without a hot FFI switch',
    () async {
      final service = _QuietStoreService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await waitForState(state);
      state.updateConfig(
        ProxyConfigModel(
          serverHost: 'old.example',
          serverPort: 1081,
          localPort: 18081,
          setSystemProxy: true,
          allowLan: true,
          tunBypassProcesses: ['browser'],
        ),
      );
      expect(state.config.setSystemProxy, isFalse);
      expect(state.config.allowLan, isFalse);
      expect(state.config.autoProxy, isFalse);
      expect(state.config.reverseGeo, isFalse);
      expect(state.config.tunBypassProcesses, isEmpty);
      expect(await state.start(), isTrue);
      calls.clear();
      failStart = true;
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = listener.listen((socket) => socket.destroy());
      addTearDown(() async {
        await subscription.cancel();
        await listener.close();
      });
      final node = NodeInfo(
        nodeId: 'candidate',
        country: 'Test',
        region: 'Loopback',
        addr: '127.0.0.1:${listener.port}',
        lastSeen: DateTime.now(),
      );
      expect(await state.switchToNode(node), isFalse);
      expect(calls.map((call) => call.method), [
        'stop',
        'start',
        'stop',
        'start',
      ]);
      expect((calls.last.arguments as Map)['serverHost'], 'old.example');
      expect(state.config.serverHost, 'old.example');
      expect(state.currentNodeId, isNull);
      expect(state.isRunning, isTrue);
      expect(state.isTunRunning, isTrue);
      expect(state.isProxyOperationInProgress, isFalse);
      expect(state.lastError, contains('restored'));
    },
    skip: !BuildCapabilities.isMacAppStore,
  );
}

Future<void> waitForState(ProxyState state) async {
  for (var i = 0; i < 100 && !state.isInitialized; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(state.isInitialized, isTrue);
}

class _QuietStoreService extends MacosStoreProxyService {
  @override
  void initLogging() {}
  @override
  void setLogLevel(int level) {}
}
