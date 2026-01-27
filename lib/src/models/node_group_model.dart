/// Node group information.
class NodeGroupModel {
  final String groupId;
  final String name;
  final List<String> nodeIds;
  final DateTime createdAt;

  NodeGroupModel({
    required this.groupId,
    required this.name,
    required this.nodeIds,
    required this.createdAt,
  });
}
