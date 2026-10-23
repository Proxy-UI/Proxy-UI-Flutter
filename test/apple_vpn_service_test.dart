import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/screens/dashboard_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/apple_packet_tunnel_proxy_service.dart';
import 'package:proxy_ui/src/ffi/proxy_ffi.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/models/proxy_config.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/services/apple_vpn_service.dart';
import 'package:proxy_ui/src/services/build_capabilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

const methods = MethodChannel('com.proxyui/apple_vpn');
const events = MethodChannel('com.proxyui/apple_vpn/events');

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
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test(
    'connected node batches stay in the provider and bound concurrency',
    () async {
      final vpn = _ProbeVpn();
      final service = ApplePacketTunnelProxyService(vpn: vpn);
      addTearDown(service.dispose);
      final results = await service.probeNodes([
        for (var i = 0; i < 33; i++) (host: 'node-$i.example', port: 1081),
      ]).toList();
      expect(results.map((value) => value.$1).toSet(), {
        for (var i = 0; i < 33; i++) i,
      });
      expect(vpn.calls, 33);
      expect(vpn.peak, 16);
      expect(results.where((value) => value.$2.success).length, 16);
      expect(results.where((value) => !value.$2.success).length, 17);
    },
  );

  test('provider probe preserves protocol and bounds its deadline', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return {
        'success': true,
        'latencyMs': 42,
        'countryCode': 'SG',
        'egressIp': '203.0.113.1',
      };
    });
    final vpn = AppleVpnService()..running = true;
    final service = ApplePacketTunnelProxyService(vpn: vpn);
    addTearDown(service.dispose);
    final probe = await service.probeNode(
      serverHost: 'node.example',
      serverPort: 1081,
      secureTransport: true,
      timeoutMs: 60000,
    );
    expect(probe.success, isTrue);
    expect(probe.latencyMs, 42);
    expect(calls.single.method, 'probeNode');
    expect(calls.single.arguments, {
      'operation': 'probeNode',
      'host': 'node.example',
      'port': 1081,
      'protocol': 3,
      'timeoutMs': 30000,
    });
  });

  testWidgets('iOS VPN page has one system connection control', (tester) async {
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
            home: Scaffold(body: DashboardPage(onOpenNodes: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('VPN Service'), findsOneWidget);
      expect(find.byIcon(Icons.security_outlined), findsNothing);
      expect(find.byIcon(Icons.help_outline), findsNothing);
      // The provider owns capture: the only control is the power button.
      expect(find.byKey(const Key('power-button')), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.textContaining('Android'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  test(
    'waits for system connection and sends only provider configuration',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final service = ApplePacketTunnelProxyService();
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
        autoProxy: true,
        reverseGeo: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(service.isRunning, isFalse);
      final config = calls.last.arguments as Map;
      expect(config['serverHost'], 'node.example');
      expect(config['autoProxy'], !BuildCapabilities.isMacAppStore);
      expect(config['reverseGeo'], !BuildCapabilities.isMacAppStore);
      expect(config['udpEnabled'], isFalse);
      expect(config['udpDirectFallback'], isFalse);
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
        await service.switchUpstream(
          serverHost: 'other.example',
          serverPort: 1,
        ),
        ProxyResult.notRunning,
      );
    },
  );

  test(
    'switches the connected provider without stopping and reports rejection',
    () async {
      final vpn = AppleVpnService()..running = true;
      final service = ApplePacketTunnelProxyService(vpn: vpn);
      addTearDown(service.dispose);
      var accepted = true;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return {
          'success': accepted,
          'error': accepted ? null : 'invalid endpoint',
        };
      });
      expect(service.supportsLiveTunSwitch, isTrue);
      expect(
        await service.switchUpstream(
          serverHost: 'quic://node.example',
          serverPort: 10811,
        ),
        ProxyResult.ok,
      );
      expect(calls.single.method, 'switchUpstream');
      expect(calls.single.arguments, {
        'operation': 'switchUpstream',
        'host': 'quic://node.example',
        'port': 10811,
      });
      accepted = false;
      expect(
        await service.switchUpstream(serverHost: 'bad/host', serverPort: 1081),
        ProxyResult.runtimeError,
      );
      expect(service.isRunning, isTrue);
      expect(service.lastError, contains('invalid endpoint'));
      expect(calls.every((call) => call.method == 'switchUpstream'), isTrue);
    },
  );

  test(
    'reports system denial instead of a successful local listener',
    () async {
      final service = ApplePacketTunnelProxyService();
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
      final vpn = AppleVpnService();
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
    'iOS node selection keeps the VPN and commits only an accepted switch',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
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
          autoProxy: true,
          reverseGeo: true,
        ),
      );
      expect(state.config.setSystemProxy, isFalse);
      expect(state.config.allowLan, isFalse);
      expect(state.config.autoProxy, !BuildCapabilities.isMacAppStore);
      expect(state.config.reverseGeo, !BuildCapabilities.isMacAppStore);
      expect(state.config.udpEnabled, isFalse);
      expect(state.config.udpDirectFallback, isFalse);
      expect(state.config.tunFakeIp, isTrue);
      expect(state.config.tunBypassProcesses, isEmpty);
      expect(await state.start(), isTrue);
      calls.clear();
      var accepted = false;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return {
          'success': accepted,
          'error': accepted ? null : 'invalid endpoint',
        };
      });
      final node = NodeInfo(
        nodeId: 'candidate',
        country: 'Test',
        region: 'Loopback',
        addr: 'quic://new.example:10811',
        lastSeen: DateTime.now(),
      );
      expect(await state.switchToNode(node), isFalse);
      expect(calls.single.method, 'switchUpstream');
      expect(state.config.serverHost, 'old.example');
      expect(state.currentNodeId, isNull);
      expect(state.isRunning, isTrue);
      expect(state.isTunRunning, isTrue);
      expect(state.isProxyOperationInProgress, isFalse);
      expect(state.lastError, contains('invalid endpoint'));
      accepted = true;
      expect(await state.switchToNode(node), isTrue);
      expect(state.config.serverHost, 'quic://new.example');
      expect(state.currentNodeId, 'candidate');
      expect(state.isRunning && state.isTunRunning, isTrue);
      expect(calls.every((call) => call.method == 'switchUpstream'), isTrue);
    },
  );
}

Future<void> waitForState(ProxyState state) async {
  for (var i = 0; i < 100 && !state.isInitialized; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(state.isInitialized, isTrue);
}

class _QuietStoreService extends ApplePacketTunnelProxyService {
  @override
  void initLogging() {}
  @override
  void setLogLevel(int level) {}
}

class _ProbeVpn extends AppleVpnService {
  _ProbeVpn() {
    running = true;
  }
  int calls = 0;
  int active = 0;
  int peak = 0;

  @override
  Future<Map<String, dynamic>> probeNode({
    required String host,
    required int port,
    required bool secureTransport,
    required int timeoutMs,
  }) async {
    calls++;
    if (!running) throw StateError('VPN disconnected');
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    active--;
    running = false;
    return {'success': true, 'latencyMs': 10};
  }
}
