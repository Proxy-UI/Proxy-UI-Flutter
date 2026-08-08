import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/node_catalog_preferences.dart';
import 'package:proxy_ui/src/models/node_model.dart';

void main() {
  test(
    'control server, sort preference, and latency survive serialization',
    () {
      final node = NodeInfo(
        nodeId: 'hk-01',
        addr: '4.193.216.253:1081',
        lastSeen: DateTime(2026, 7, 19),
        country: 'HK',
        region: 'Hong Kong',
      );
      final original = const NodeCatalogPreferences(
        serverHost: 'control.example.com',
        serverPort: 8443,
        sessionKey: 'test-session-key',
        sortByLatency: true,
      ).withLatency(node, 42);

      final restored = NodeCatalogPreferences.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.serverHost, 'control.example.com');
      expect(restored.serverPort, 8443);
      expect(restored.sessionKey, 'test-session-key');
      expect(restored.sortByLatency, isTrue);
      expect(restored.latencyFor(node), 42);
    },
  );

  test('latency is scoped to both node id and address', () {
    final original = NodeInfo(
      nodeId: 'node-01',
      addr: '10.0.0.1:1081',
      lastSeen: DateTime(2026, 7, 19),
      country: 'SG',
      region: 'Singapore',
    );
    final moved = NodeInfo(
      nodeId: 'node-01',
      addr: '10.0.0.2:1081',
      lastSeen: DateTime(2026, 7, 19),
      country: 'SG',
      region: 'Singapore',
    );
    final preferences = const NodeCatalogPreferences().withLatency(
      original,
      25,
    );

    expect(preferences.latencyFor(original), 25);
    expect(preferences.latencyFor(moved), isNull);
  });

  test('restores legacy control server and address-keyed latency payloads', () {
    final node = NodeInfo(
      nodeId: 'legacy-node',
      addr: '10.0.0.8:1081',
      lastSeen: DateTime(2026, 7, 19),
      country: 'SG',
      region: 'Singapore',
    );
    final restored = NodeCatalogPreferences.fromLegacyJson(
      server: const {
        'host': 'legacy.example.com',
        'port': 1088,
        'sessionKey': 'legacy-key',
      },
      latencies: const {'10.0.0.8:1081': 37},
    );

    expect(restored.serverHost, 'legacy.example.com');
    expect(restored.serverPort, 1088);
    expect(restored.sessionKey, 'legacy-key');
    expect(restored.latencyFor(node), 37);
    expect(restored.legacyLatencies, {'10.0.0.8:1081': 37});
  });
}
