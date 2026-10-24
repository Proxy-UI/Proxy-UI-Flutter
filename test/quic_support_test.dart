import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/models/node_catalog_preferences.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/models/quic_support.dart';
import 'package:proxy_ui/src/models/upstream_endpoint.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_proxy_service.dart';

NodeInfo _node(String addr) => NodeInfo(
  nodeId: addr,
  addr: addr,
  lastSeen: DateTime.now(),
  country: '',
  region: '',
);

final _serving = _node('a.example:1081');
final _without = _node('b.example:1081');
final _addressed = _node('quic://c.example:10811');
final _unknown = _node('d.example:1081');

/// [_without] was last tested over TCP, before any QUIC test.
final _earlier = NodeVerification(
  status: NodeVerificationStatus.verified,
  checkedAt: DateTime.now().subtract(const Duration(minutes: 5)),
  countryCode: 'JP',
  egressIp: '198.51.100.2',
  latencyMs: 90,
);

/// A state over the four nodes, configured for [server] when given.
Future<ProxyState> _state(
  FakeProxyService service, {
  ({String host, int port})? server,
}) async {
  SharedPreferences.setMockInitialValues({
    'node_catalog_preferences': jsonEncode(
      NodeCatalogPreferences(
        serverHost: 'a.example',
        nodes: [_serving, _without, _addressed, _unknown],
        verifications: {_without.storageKey: _earlier},
        latencies: {_without.storageKey: 90},
      ).toJson(),
    ),
    if (server != null)
      'proxy_config': jsonEncode({
        'serverHost': server.host,
        'serverPort': server.port,
        'setSystemProxy': false,
      }),
  });
  final state = ProxyState(service: service);
  addTearDown(state.dispose);
  while (!state.isInitialized) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return state;
}

FakeProxyService _service({bool rejects = false}) => FakeProxyService(
  rejectsQuicLookup: rejects,
  quicSupport: {
    'a.example:1081': const QuicSupport.at(10811),
    'b.example:1081': QuicSupport.none,
  },
  probes: {
    'quic://a.example:10811': const NodeProbe(
      success: true,
      countryCode: 'JP',
      egressIp: '198.51.100.1',
      latencyMs: 70,
    ),
    'quic://c.example:10811': const NodeProbe(
      success: false,
      error: 'certificate is not valid for c.example',
    ),
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('QuicSupport.fromJson', () {
    test('a port is QUIC, a plain no is none, an error is unknown', () {
      final at = QuicSupport.fromJson({
        'available': true,
        'port': 10811,
        'address': 'quic://a.example:10811',
      });
      expect(at.isAvailable, isTrue);
      expect(at.port, 10811);
      expect(QuicSupport.fromJson({'available': false}), QuicSupport.none);
      for (final unknown in [
        {'available': false, 'error': 'node predates the question'},
        {'available': true},
        {'available': true, 'port': 0},
        'garbage',
        null,
      ]) {
        expect(QuicSupport.fromJson(unknown), QuicSupport.unknown);
      }
    });
  });

  test('verifications keep their carrier, and older ones read as TCP', () {
    final quic = NodeVerification(
      status: NodeVerificationStatus.verified,
      checkedAt: DateTime.now(),
      latencyMs: 70,
      carrier: UpstreamTransport.quic,
    );
    expect(
      NodeVerification.fromJson(jsonDecode(jsonEncode(quic.toJson())))!.carrier,
      UpstreamTransport.quic,
    );
    final legacy = quic.toJson()..remove('carrier');
    expect(NodeVerification.fromJson(legacy)!.carrier, UpstreamTransport.tcp);
  });

  test('the catalogue is asked once, without its quic:// entries', () async {
    final service = _service();
    final state = await _state(service);

    await state.lookUpQuicSupport();
    await state.lookUpQuicSupport();
    expect(service.calls.where((call) => call.startsWith('quic ')), [
      'quic a.example:1081,b.example:1081,d.example:1081',
    ]);
    expect(state.quicSupportOf(_serving).port, 10811);
    expect(state.quicSupportOf(_without), QuicSupport.none);
    expect(state.quicSupportOf(_addressed).port, 10811);
    expect(state.quicSupportOf(_unknown), QuicSupport.unknown);

    // A new key is a new catalogue: it is asked again.
    state.updateNodesServerConfig(sessionKey: 'rotated');
    expect(state.hasAskedQuicSupport, isFalse);
    expect(state.quicSupportOf(_serving), QuicSupport.unknown);
  });

  test(
    'a library that rejects the question leaves every node unknown',
    () async {
      final state = await _state(_service(rejects: true));
      await state.lookUpQuicSupport();
      expect(state.quicSupportOf(_serving), QuicSupport.unknown);
      expect(state.endpointOf(_serving, UpstreamTransport.quic), isNull);
      // Its own address is still QUIC, and it has no other.
      expect(
        state.endpointOf(_addressed, UpstreamTransport.quic)?.qualifiedHost,
        'quic://c.example',
      );
      expect(state.endpointOf(_addressed, UpstreamTransport.tcp), isNull);
    },
  );

  test('each carrier keeps its own result', () async {
    final service = _service();
    final state = await _state(service);
    await state.lookUpQuicSupport();
    service.calls.clear();

    final results = await state.verifyNodes([
      _serving,
      _without,
      _addressed,
      _unknown,
    ], carrier: UpstreamTransport.quic);

    expect(service.calls.where((call) => call.startsWith('probe ')).toSet(), {
      'probe quic://a.example:10811',
      'probe quic://c.example:10811',
    });
    expect(results[0]?.latencyMs, 70);
    expect(results[1], isNull);
    expect(results[2]?.error, contains('certificate'));
    expect(results[3], isNull);

    // A QUIC answer sits beside the TCP one instead of replacing it, and
    // lacking QUIC says nothing about the TCP result a node already had.
    expect(
      state.verificationFor(_serving, UpstreamTransport.quic)?.latencyMs,
      70,
    );
    expect(state.verificationFor(_serving, UpstreamTransport.tcp), isNull);
    expect(state.latencyOf(_serving, UpstreamTransport.tcp), isNull);
    expect(state.verificationFor(_without)?.latencyMs, 90);
    expect(state.verificationFor(_unknown), isNull);

    final saved = NodeCatalogPreferences.fromJson(
      jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          'node_catalog_preferences',
        )!,
      ),
    );
    expect(
      saved.verificationFor(_serving, UpstreamTransport.quic)?.latencyMs,
      70,
    );
    expect(saved.verificationFor(_serving), isNull);
    expect(saved.verificationFor(_addressed)?.carrier, UpstreamTransport.quic);
  });

  test('a QUIC result the last build kept as the only one moves aside', () {
    final quic = NodeVerification(
      status: NodeVerificationStatus.verified,
      checkedAt: DateTime.now(),
      latencyMs: 70,
      carrier: UpstreamTransport.quic,
    );
    // Builds older still recorded a `quic://` entry's results as TCP.
    final unlabelled = quic.toJson()..remove('carrier');
    final restored = NodeCatalogPreferences.fromJson({
      'verifications': {
        _serving.storageKey: quic.toJson(),
        _addressed.storageKey: unlabelled,
      },
      'latencies': {_serving.storageKey: 70, _addressed.storageKey: 70},
    });

    expect(restored.verificationFor(_serving), isNull);
    expect(restored.latencyFor(_serving), isNull);
    expect(
      restored.verificationFor(_serving, UpstreamTransport.quic)?.latencyMs,
      70,
    );
    expect(restored.verificationFor(_addressed)?.latencyMs, 70);
    expect(restored.latencyFor(_addressed), 70);
  });

  test(
    'the node in use is found over QUIC, and connecting follows the carrier',
    () async {
      final service = _service();
      // The port a carrier switch used to leave behind: a.example's TCP one.
      final state = await _state(
        service,
        server: (host: 'quic://a.example', port: 1081),
      );

      // No other node shares the host, so it is found before QUIC is known.
      expect(state.isCurrentNode(_serving), isTrue);
      expect(state.isCurrentNode(_without), isFalse);
      await state.lookUpQuicSupport();
      expect(state.isCurrentNode(_serving), isTrue);
      // Until one is picked, the map uses the configured server's carrier.
      expect(state.preferredCarrier, UpstreamTransport.quic);
      expect(state.carrierFor(_serving), UpstreamTransport.quic);
      expect(state.carrierFor(_without), UpstreamTransport.tcp);
      // UDP 1081 is not where it serves QUIC, so connecting still means
      // something.
      expect(state.isInUse(_serving), isFalse);

      expect(await state.switchToNode(_serving), isTrue);
      expect(service.calls.last, 'start quic://a.example:10811');
      expect(state.isInUse(_serving), isTrue);

      state.setPreferredCarrier(UpstreamTransport.tcp);
      expect(state.isInUse(_serving), isFalse);
      expect(state.switchImpactOf(_serving), SwitchImpact.newSessions);
      expect(await state.switchToNode(_serving), isTrue);
      expect(service.calls.last, 'switch a.example:1081');
      expect(state.isCurrentNode(_serving), isTrue);
      expect(state.currentCarrier, UpstreamTransport.tcp);
    },
  );
}
