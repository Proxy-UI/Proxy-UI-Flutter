import 'node_group_model.dart';
import 'node_model.dart';

/// Filters the node catalog by the selected group and a free-form query.
///
/// Every whitespace-separated search term must match the node's identifier,
/// address, location, or the name of one of its groups. Group selection and
/// text search are intentionally combined so switching groups never discards
/// the user's search.
/// The country to filter and group by.
///
/// Verification observes where a node's traffic actually leaves from, which is
/// the answer a user picking "show me Japan" wants, so it wins over whatever
/// the catalogue recorded.
typedef NodeCountryResolver = String Function(NodeInfo node);

String _claimedCountry(NodeInfo node) => node.country;

/// Countries present in the catalogue, most populated first, then alphabetical.
List<({String code, int count})> countryFacets({
  required List<NodeInfo> nodes,
  NodeCountryResolver countryOf = _claimedCountry,
}) {
  final counts = <String, int>{};
  for (final node in nodes) {
    final code = countryOf(node).trim().toUpperCase();
    if (code.isEmpty) continue;
    counts[code] = (counts[code] ?? 0) + 1;
  }
  final facets = counts.entries
      .map((entry) => (code: entry.key, count: entry.value))
      .toList();
  facets.sort((left, right) {
    final byCount = right.count.compareTo(left.count);
    return byCount != 0 ? byCount : left.code.compareTo(right.code);
  });
  return facets;
}

List<NodeInfo> filterNodeCatalog({
  required List<NodeInfo> nodes,
  required List<NodeGroupModel> groups,
  String? selectedGroupId,
  String? selectedCountry,
  String query = '',
  bool sortByLatency = false,
  NodeCountryResolver countryOf = _claimedCountry,
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

  final wantedCountry = selectedCountry?.trim().toUpperCase();

  final filtered = nodes.where((node) {
    if (selectedNodeIds != null && !selectedNodeIds.contains(node.nodeId)) {
      return false;
    }
    final country = countryOf(node).trim().toUpperCase();
    if (wantedCountry != null &&
        wantedCountry.isNotEmpty &&
        country != wantedCountry) {
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

    return terms.every((term) {
      // A bare two-letter term reads as a country code. Matching it as a
      // substring instead would drag in every node whose address or identifier
      // happens to contain those letters, which is most of them.
      if (term.length == 2 && RegExp(r'^[a-z]{2}$').hasMatch(term)) {
        return country == term.toUpperCase() ||
            node.country.trim().toUpperCase() == term.toUpperCase();
      }
      return searchableText.contains(term);
    });
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
