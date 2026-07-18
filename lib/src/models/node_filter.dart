import 'node_group_model.dart';
import 'node_model.dart';

/// Filters the node catalog by the selected group and a free-form query.
///
/// Every whitespace-separated search term must match the node's identifier,
/// address, location, or the name of one of its groups. Group selection and
/// text search are intentionally combined so switching groups never discards
/// the user's search.
List<NodeInfo> filterNodeCatalog({
  required List<NodeInfo> nodes,
  required List<NodeGroupModel> groups,
  String? selectedGroupId,
  String query = '',
  bool sortByLatency = false,
}) {
  final selectedNodeIds = selectedGroupId == null
      ? null
      : groups
            .where((group) => group.groupId == selectedGroupId)
            .expand((group) => group.nodeIds)
            .toSet();
  final groupNamesByNodeId = <String, List<String>>{};
  for (final group in groups) {
    for (final nodeId in group.nodeIds) {
      groupNamesByNodeId.putIfAbsent(nodeId, () => []).add(group.name);
    }
  }
  final terms = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList();

  final filtered = nodes.where((node) {
    if (selectedNodeIds != null && !selectedNodeIds.contains(node.nodeId)) {
      return false;
    }
    if (terms.isEmpty) {
      return true;
    }

    final searchableText = [
      node.nodeId,
      node.addr,
      node.country,
      node.region,
      node.displayName,
      ...?groupNamesByNodeId[node.nodeId],
    ].join(' ').toLowerCase();
    return terms.every(searchableText.contains);
  }).toList();
  if (sortByLatency) {
    final serverOrder = {
      for (var index = 0; index < nodes.length; index++) nodes[index]: index,
    };
    filtered.sort((left, right) {
      final leftLatency = left.latencyMs;
      final rightLatency = right.latencyMs;
      if (leftLatency == null) {
        return rightLatency == null
            ? serverOrder[left]!.compareTo(serverOrder[right]!)
            : 1;
      }
      if (rightLatency == null) return -1;
      final latencyOrder = leftLatency.compareTo(rightLatency);
      return latencyOrder != 0
          ? latencyOrder
          : serverOrder[left]!.compareTo(serverOrder[right]!);
    });
  }
  return filtered;
}
