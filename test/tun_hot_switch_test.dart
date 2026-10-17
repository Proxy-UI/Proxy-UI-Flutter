import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/proxy_ffi.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/models/proxy_config.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'elevation handoff waits for native cleanup and preserves TUN intent',
    () async {
      final service = _FakeProxyService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await _waitUntilInitialized(state);
      state.updateConfig(
        ProxyConfigModel(serverHost: 'node.example', setSystemProxy: false),
      );
      expect(await state.start(), isTrue);
      state.updateConfig(state.config.copyWith(tunEnabled: true));
      service.stopGate = Completer<void>();
      var completed = false;
      final handoff = state.stopForElevationHandoff().then((result) {
        completed = true;
        return result;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(state.isRunning, isTrue);
      expect(state.isProxyOperationInProgress, isTrue);
      expect(await state.start(), isFalse);
      service.stopGate!.complete();
      expect(await handoff, isTrue);
      expect(state.isRunning, isFalse);
      expect(state.config.tunEnabled, isTrue);
      expect(state.isProxyOperationInProgress, isFalse);
    },
  );

  test(
    'failed elevation cleanup keeps the old listener visible and permits retry',
    () async {
      final service = _FakeProxyService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await _waitUntilInitialized(state);
      state.updateConfig(
        ProxyConfigModel(serverHost: 'node.example', setSystemProxy: false),
      );
      expect(await state.start(), isTrue);
      service.stopResult = ProxyResult.runtimeError;
      expect(await state.stopForElevationHandoff(), isFalse);
      expect(state.isRunning, isTrue);
      expect(state.lastError, isNotNull);
      expect(state.isProxyOperationInProgress, isFalse);
      service.stopResult = ProxyResult.ok;
      expect(await state.stopForElevationHandoff(), isTrue);
    },
  );

  test(
    'stop reaches pending native cleanup and propagates its failure',
    () async {
      final service = _FakeProxyService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await _waitUntilInitialized(state);
      service.stopResult = ProxyResult.runtimeError;
      expect(await state.stop(), isFalse);
      expect(service.calls, ['stop']);
      service.stopResult = ProxyResult.ok;
      expect(await state.stop(), isTrue);
    },
  );

  test(
    'disposing during initialization cannot start the elevated handoff',
    () async {
      final service = _FakeProxyService();
      final state = ProxyState(service: service, enableTunOnStartup: true);
      state.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await state.start(), isFalse);
      expect(await state.setTunEnabled(true), isFalse);
      expect(service.listenerStartCount, 0);
    },
  );

  test(
    'Fake-IP is opt-in and reaches the native service on reconnect',
    () async {
      final service = _FakeProxyService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await _waitUntilInitialized(state);
      state.updateConfig(
        ProxyConfigModel(serverHost: 'node.example', setSystemProxy: false),
      );
      expect(await state.start(), isTrue);
      expect(service.lastTunFakeIp, isFalse);
      expect(service.lastTunDnsServer, '223.5.5.5');
      expect(await state.stop(), isTrue);
      state.updateConfig(
        state.config.copyWith(tunFakeIp: true, tunDnsServer: '10.20.30.53'),
      );
      expect(await state.start(), isTrue);
      expect(service.lastTunFakeIp, isTrue);
      expect(service.lastTunDnsServer, '10.20.30.53');
      expect(await state.stop(), isTrue);
    },
  );

  test(
    'a silent native failure updates status without waiting for logs',
    () async {
      final service = _FakeProxyService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await _waitUntilInitialized(state);
      state.updateConfig(
        ProxyConfigModel(serverHost: 'node.example', setSystemProxy: false),
      );
      expect(await state.start(), isTrue);
      expect(await state.setTunEnabled(true), isTrue);
      service.simulateListenerLoss();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(state.isRunning, isFalse);
      expect(
        state.isTunRunning,
        isTrue,
        reason: 'surviving capture must remain visible and stoppable',
      );
      expect(await state.stop(), isTrue);
      expect(state.isTunRunning, isFalse);
    },
  );

  test(
    'applying bypass repeatedly preserves the running TUN and listener',
    () async {
      final service = _FakeProxyService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await _waitUntilInitialized(state);
      state.updateConfig(
        ProxyConfigModel(
          serverHost: 'node.example',
          serverPort: 1081,
          localPort: 18080,
          setSystemProxy: false,
        ),
      );
      expect(await state.start(), isTrue);
      expect(await state.setTunEnabled(true), isTrue);
      service.calls.clear();

      for (final processes in [
        <String>['browser'],
        ['browser', 'game'],
        ['game'],
        <String>[],
      ]) {
        expect(await state.updateTunBypassProcesses(processes), isTrue);
        expect(service.lastBypassProcesses, processes);
        expect(state.config.tunBypassProcesses, processes);
        expect(state.isRunning, isTrue);
        expect(state.isTunRunning, isTrue);
      }
      expect(service.calls, List.filled(4, 'setTunBypassProcesses'));
      expect(service.listenerStartCount, 1);
    },
  );

  test(
    'active TUN switches upstream without restarting the local listener',
    () async {
      final service = _FakeProxyService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await _waitUntilInitialized(state);

      state.updateConfig(
        ProxyConfigModel(
          serverHost: 'old.example',
          serverPort: 1081,
          localPort: 18080,
          allowLan: true,
          setSystemProxy: false,
        ),
      );
      expect(await state.start(), isTrue);
      expect(service.lastAllowLan, isTrue);
      expect(await state.setTunEnabled(true), isTrue);
      service.calls.clear();

      final target = await _reachableNode('new-node');
      addTearDown(target.close);

      expect(await state.switchToNode(target.node), isTrue);
      expect(service.calls, [
        'stopTun',
        'switch:${target.node.addr}',
        'startTun',
      ]);
      expect(service.listenerStartCount, 1);
      expect(state.isRunning, isTrue);
      expect(state.isTunRunning, isTrue);
      expect(state.config.serverHost, target.node.host);
      expect(state.config.serverPort, target.node.port);
      expect(state.config.localPort, 18080);
      expect(state.config.allowLan, isTrue);
      expect(state.currentNodeId, 'new-node');
    },
  );

  test('stopping tears TUN down even when the listener is already gone', () async {
    final service = _FakeProxyService();
    final state = ProxyState(service: service);
    addTearDown(state.dispose);
    await _waitUntilInitialized(state);

    state.updateConfig(
      ProxyConfigModel(
        serverHost: 'node.example',
        serverPort: 1081,
        localPort: 18081,
        setSystemProxy: false,
      ),
    );
    expect(await state.start(), isTrue);
    expect(await state.setTunEnabled(true), isTrue);

    // The listener dies but capture does not, which is where TUN owns the system
    // routes and DNS with nothing left to release them.
    service.simulateListenerLoss();
    service.calls.clear();

    expect(await state.stop(), isTrue);
    // Either route is acceptable — `stop` reaches native, whose `!running`
    // branch cancels TUN, or the provider asks for teardown directly. What must
    // not happen is returning with capture still active and its DNS installed.
    expect(
      service.calls.isNotEmpty,
      isTrue,
      reason: 'stopping must reach native so TUN routes and DNS are restored',
    );
    expect(state.isTunRunning, isFalse);
    expect(service.isTunRunning, isFalse);
  });

  test(
    'live TUN switch stays responsive and keeps capture on failure or success',
    () async {
      final service = _FakeProxyService()..supportsLiveTunSwitch = true;
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await _waitUntilInitialized(state);
      state.updateConfig(
        ProxyConfigModel(serverHost: 'old.example', setSystemProxy: false),
      );
      expect(await state.start(), isTrue);
      expect(await state.setTunEnabled(true), isTrue);
      service.calls.clear();
      final node = NodeInfo(
        nodeId: 'next',
        addr: 'new.example:2081',
        lastSeen: DateTime.now(),
        country: 'Test',
        region: 'Loopback',
      );

      for (final result in [ProxyResult.runtimeError, ProxyResult.ok]) {
        service.switchGate = Completer<int>();
        final switching = state.switchToNode(node);
        await Future<void>.delayed(Duration.zero);
        expect(state.isTunBusy, isTrue);
        expect(state.isRunning, isTrue);
        expect(state.isTunRunning, isTrue);
        expect(state.config.serverHost, 'old.example');
        expect(await state.stop(), isFalse);
        await expectLater(state.switchToNode(node), throwsStateError);
        service.switchGate!.complete(result);
        expect(await switching, result == ProxyResult.ok);
        expect(state.isTunBusy, isFalse);
        expect(state.isProxyOperationInProgress, isFalse);
        expect(state.isTunRunning, isTrue);
        if (result != ProxyResult.ok) {
          expect(state.lastError, contains('bypass update exceeded'));
          expect(state.config.serverHost, 'old.example');
          expect(state.currentNodeId, isNull);
        }
      }
      expect(state.config.serverHost, 'new.example');
      expect(state.currentNodeId, 'next');
      expect(service.calls, [
        'switch:new.example:2081',
        'switch:new.example:2081',
      ]);
      expect(service.listenerStartCount, 1);
    },
  );

  test(
    'failed TUN restart restores the previous upstream and routes',
    () async {
      final service = _FakeProxyService();
      final state = ProxyState(service: service);
      addTearDown(state.dispose);
      await _waitUntilInitialized(state);

      state.updateConfig(
        ProxyConfigModel(
          serverHost: 'old.example',
          serverPort: 1081,
          localPort: 18080,
          setSystemProxy: false,
        ),
      );
      expect(await state.start(), isTrue);
      expect(await state.setTunEnabled(true), isTrue);
      service.calls.clear();
      service.tunStartResults.addAll([
        ProxyResult.runtimeError,
        ProxyResult.ok,
      ]);

      final target = await _reachableNode('failing-node');
      addTearDown(target.close);

      expect(await state.switchToNode(target.node), isFalse);
      expect(service.calls, [
        'stopTun',
        'switch:${target.node.addr}',
        'startTun',
        'switch:old.example:1081',
        'startTun',
      ]);
      expect(service.listenerStartCount, 1);
      expect(state.isRunning, isTrue);
      expect(state.isTunRunning, isTrue);
      expect(state.config.serverHost, 'old.example');
      expect(state.config.serverPort, 1081);
      expect(state.currentNodeId, isNull);
      expect(
        state.lastError,
        contains('Previous node and TUN routes were restored'),
      );
    },
  );
}

Future<void> _waitUntilInitialized(ProxyState state) async {
  for (var attempt = 0; attempt < 50 && !state.isInitialized; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(state.isInitialized, isTrue);
}

Future<_ReachableNode> _reachableNode(String id) async {
  final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = listener.first.then((socket) => socket.destroy());
  return _ReachableNode(
    node: NodeInfo(
      nodeId: id,
      addr: '127.0.0.1:${listener.port}',
      lastSeen: DateTime.now(),
      country: 'Test',
      region: 'Loopback',
    ),
    close: () async {
      await accepted;
      await listener.close();
    },
  );
}

class _ReachableNode {
  const _ReachableNode({required this.node, required this.close});

  final NodeInfo node;
  final Future<void> Function() close;
}

class _FakeProxyService extends ProxyService {
  @override
  bool supportsLiveTunSwitch = false;
  Completer<int>? switchGate;
  var stopResult = ProxyResult.ok;
  Completer<void>? stopGate;
  final List<String> calls = [];
  final Queue<int> tunStartResults = Queue<int>();
  var listenerStartCount = 0;
  var lastAllowLan = false;
  var lastTunFakeIp = false;
  var lastTunDnsServer = '';
  List<String> lastBypassProcesses = [];
  var _running = false;
  var _tunRunning = false;
  String? _error;

  @override
  void initLogging() {}

  @override
  Future<int> start({
    required String serverHost,
    required int serverPort,
    int localPort = 1080,
    String? sessionKey,
    bool autoProxy = true,
    bool udpEnabled = true,
    bool udpDirectFallback = true,
    bool tunEnabled = false,
    bool tunFakeIp = false,
    String tunDnsServer = '223.5.5.5',
    List<String> tunBypassProcesses = const [],
    bool reverseGeo = false,
    bool secureTransport = false,
    bool setSystemProxy = false,
    bool allowLan = false,
  }) async {
    listenerStartCount++;
    lastAllowLan = allowLan;
    lastTunFakeIp = tunFakeIp;
    lastTunDnsServer = tunDnsServer;
    _running = true;
    _error = null;
    return ProxyResult.ok;
  }

  @override
  Future<int> startTun(List<String> processes) async {
    calls.add('startTun');
    final result = tunStartResults.isEmpty
        ? ProxyResult.ok
        : tunStartResults.removeFirst();
    _tunRunning = result == ProxyResult.ok;
    _error = result == ProxyResult.ok ? null : 'simulated TUN restart failure';
    return result;
  }

  @override
  Future<int> stopTun() async {
    calls.add('stopTun');
    _tunRunning = false;
    _error = null;
    return ProxyResult.ok;
  }

  @override
  int setTunBypassProcesses(List<String> processes) {
    calls.add('setTunBypassProcesses');
    lastBypassProcesses = List.of(processes);
    return ProxyResult.ok;
  }

  @override
  Future<int> switchUpstream({
    required String serverHost,
    required int serverPort,
  }) async {
    calls.add('switch:$serverHost:$serverPort');
    final result = await switchGate?.future ?? ProxyResult.ok;
    if (result != ProxyResult.ok) {
      _error = 'TUN upstream bypass update exceeded 5 seconds';
      return result;
    }
    _error = null;
    return ProxyResult.ok;
  }

  @override
  Future<int> stop() async {
    calls.add('stop');
    await stopGate?.future;
    if (stopResult != ProxyResult.ok) return stopResult;
    _running = false;
    _tunRunning = false;
    return ProxyResult.ok;
  }

  /// Drop the listener without touching TUN, reproducing the inconsistent state
  /// a partially failed stop leaves behind.
  void simulateListenerLoss() {
    _running = false;
  }

  @override
  bool get isRunning => _running;

  @override
  bool get isTunRunning => _tunRunning;

  @override
  bool get isElevated => true;

  @override
  String? get lastError => _error;

  @override
  void dispose() {}
}
