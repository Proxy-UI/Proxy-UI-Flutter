import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/country_atlas.dart';
import 'package:proxy_ui/src/models/node_health.dart';
import 'package:proxy_ui/src/models/node_model.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_model.dart';
import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_view.dart';

GalaxyNode node(
  String addr,
  String country, {
  NodeHealth health = NodeHealth.fast,
  bool current = false,
}) => GalaxyNode(
  node: NodeInfo(
    nodeId: addr,
    addr: addr,
    lastSeen: DateTime(2026),
    country: '',
    region: '',
  ),
  country: country,
  health: health,
  current: current,
);

void main() {
  // East Asia is where real catalogues crowd: these countries sit within a
  // few degrees of each other.
  final crowded = [
    for (final code in ['HK', 'MO', 'CN', 'TW', 'JP', 'KR', 'SG', 'PH'])
      for (var i = 0; i < 5; i++) node('$code-$i:1081', code),
    for (var i = 0; i < 12; i++) node('us-$i:1081', 'US'),
    for (var i = 0; i < 9; i++)
      node('lost-$i:1081', '', health: NodeHealth.unreachable),
  ];

  test('systems never overlap and keep clear of the home star', () {
    final scene = buildGalaxyScene(crowded);
    for (final system in scene.systems) {
      expect(
        system.position.length,
        greaterThanOrEqualTo(system.extent + 1.4),
        reason: '${system.code} crowds the home star',
      );
    }
    for (var i = 0; i < scene.systems.length; i++) {
      for (var j = i + 1; j < scene.systems.length; j++) {
        final a = scene.systems[i], b = scene.systems[j];
        expect(
          (a.position - b.position).length,
          greaterThan(a.extent + b.extent),
          reason: '${a.code} overlaps ${b.code}',
        );
      }
    }
  });

  test('countries keep their geographic neighbourhood', () {
    final scene = buildGalaxyScene(crowded);
    Vec3 at(String code) => scene.systemOf(systemIdFor(code))!.position;
    // Hong Kong is far nearer Macao than the United States.
    expect(
      (at('HK') - at('MO')).length,
      lessThan((at('HK') - at('US')).length / 2),
    );
    // Seen from above the North Pole with Asia nearest the viewer, the
    // Americas are on the far side.
    expect(at('US').dot(at('JP')), lessThan(0));
  });

  test('state changes never move a system; filters keep positions', () {
    final before = buildGalaxyScene(crowded);
    final changed = buildGalaxyScene([
      for (final n in crowded)
        node(
          n.node.addr,
          n.country,
          health: NodeHealth.slow,
          current: n.node.addr == 'JP-1:1081',
        ),
    ]);
    for (final system in before.systems) {
      expect(
        changed.systemOf(system.id)!.position.toString(),
        system.position.toString(),
      );
    }
    final filtered = filterGalaxyScene(before, (n) => n.country == 'JP');
    expect(filtered.systems.single.code, 'JP');
    expect(
      filtered.systems.single.position.toString(),
      before.systemOf(systemIdFor('JP'))!.position.toString(),
    );
  });

  test('unlocated nodes gather outside every known country', () {
    final scene = buildGalaxyScene(crowded);
    final unlocated = scene.systemOf(systemIdFor(''))!;
    expect(unlocated.planets, hasLength(9));
    final known = scene.systems.where((s) => !s.unknown);
    expect(
      unlocated.position.length,
      greaterThan(
        known.map((s) => s.position.length).reduce((a, b) => a > b ? a : b),
      ),
    );
  });

  test('a node located by a test flies from the unlocated cluster', () {
    final view = GalaxyView();
    addTearDown(view.dispose);
    final lost = node('203.0.113.9:1081', '', health: NodeHealth.untested);
    view.update(buildGalaxyScene([lost, node('a:1', 'JP')]), first: true);
    view.time = 5;
    view.update(
      buildGalaxyScene([node('203.0.113.9:1081', 'US'), node('a:1', 'JP')]),
      first: false,
    );
    expect(view.migrations.keys, [lost.id]);
    expect(view.appeared, isEmpty);
  });

  test('health reflects the last verification before any older latency', () {
    final checked = DateTime(2026);
    expect(
      nodeHealthOf(
        testing: false,
        latencyMs: 120,
        verification: NodeVerification(
          status: NodeVerificationStatus.unreachable,
          checkedAt: checked,
        ),
      ),
      NodeHealth.unreachable,
    );
    expect(
      nodeHealthOf(
        testing: false,
        verification: NodeVerification(
          status: NodeVerificationStatus.verified,
          checkedAt: checked,
          latencyMs: NodeHealth.fairLatencyMs,
        ),
      ),
      NodeHealth.slow,
    );
    expect(nodeHealthOf(testing: false), NodeHealth.untested);
    expect(nodeHealthOf(testing: true, latencyMs: 80), NodeHealth.testing);
  });

  test('country codes come from free text and legacy spellings', () {
    expect(normalizeCountryCode('us - Virginia'), 'US');
    expect(normalizeCountryCode('UK'), 'GB');
    expect(normalizeCountryCode('Hong Kong'), '');
    expect(countryName('HK', 'zh'), '中国香港');
    expect(countryName('ZZ', 'en'), 'ZZ');
  });
}
