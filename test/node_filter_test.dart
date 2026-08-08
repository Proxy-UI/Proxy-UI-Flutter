import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/node_filter.dart';
import 'package:proxy_ui/src/models/node_group_model.dart';
import 'package:proxy_ui/src/models/node_model.dart';

void main() {
  final now = DateTime(2026, 7, 19);
  final nodes = [
    NodeInfo(
      nodeId: 'hk-01',
      addr: '4.193.216.253:1081',
      lastSeen: now,
      country: 'HK',
      region: 'Hong Kong',
    ),
    NodeInfo(
      nodeId: 'sg-01',
      addr: '10.0.0.2:1081',
      lastSeen: now,
      country: 'SG',
      region: 'Singapore',
    ),
    NodeInfo(
      nodeId: 'us-01',
      addr: '10.0.0.3:1081',
      lastSeen: now,
      country: 'US',
      region: 'Los Angeles',
    ),
  ];
  final groups = [
    NodeGroupModel(
      groupId: 'asia',
      name: 'Asia Premium',
      nodeIds: const ['hk-01', 'sg-01'],
      createdAt: now,
    ),
    NodeGroupModel(
      groupId: 'gaming',
      name: 'Gaming Routes',
      nodeIds: const ['hk-01', 'us-01'],
      createdAt: now,
    ),
  ];

  test('returns every node when no filter is active', () {
    expect(
      filterNodeCatalog(nodes: nodes, groups: groups),
      hasLength(nodes.length),
    );
  });

  test('searches node identity, location, and address case-insensitively', () {
    expect(
      filterNodeCatalog(nodes: nodes, groups: groups, query: 'HONG kong'),
      [nodes[0]],
    );
    expect(
      filterNodeCatalog(nodes: nodes, groups: groups, query: '4.193.216'),
      [nodes[0]],
    );
    expect(filterNodeCatalog(nodes: nodes, groups: groups, query: 'SG-01'), [
      nodes[1],
    ]);
  });

  test('searching a group name returns the nodes in that group', () {
    expect(
      filterNodeCatalog(nodes: nodes, groups: groups, query: 'gaming routes'),
      [nodes[0], nodes[2]],
    );
  });

  test('selected group and search query are intersected', () {
    expect(
      filterNodeCatalog(
        nodes: nodes,
        groups: groups,
        selectedGroupId: 'asia',
        query: 'Singapore',
      ),
      [nodes[1]],
    );
    expect(
      filterNodeCatalog(
        nodes: nodes,
        groups: groups,
        selectedGroupId: 'asia',
        query: 'Los Angeles',
      ),
      isEmpty,
    );
  });

  test('latency sorting keeps untested nodes last', () {
    nodes[0].latencyMs = 80;
    nodes[2].latencyMs = 20;

    expect(
      filterNodeCatalog(nodes: nodes, groups: groups, sortByLatency: true),
      [nodes[2], nodes[0], nodes[1]],
    );
  });
}
