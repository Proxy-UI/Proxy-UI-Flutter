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
  final List<String> calls = [];
  final Queue<int> tunStartResults = Queue<int>();
  var listenerStartCount = 0;
  var lastAllowLan = false;
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
    List<String> tunBypassProcesses = const [],
    bool reverseGeo = false,
    String? needCodecIps,
    bool forceCodec = false,
    bool setSystemProxy = false,
    bool allowLan = false,
  }) async {
    listenerStartCount++;
    lastAllowLan = allowLan;
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
  int switchUpstream({required String serverHost, required int serverPort}) {
    calls.add('switch:$serverHost:$serverPort');
    _error = null;
    return ProxyResult.ok;
  }

  @override
  int stop() {
    _running = false;
    _tunRunning = false;
    return ProxyResult.ok;
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
