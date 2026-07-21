import '../ffi/proxy_service.dart';

/// One executable group in the application hierarchy rendered by the picker.
class TunProcessTreeNode {
  final TunProcessInfo process;
  final String? parentName;
  final List<TunProcessTreeNode> children;

  const TunProcessTreeNode({
    required this.process,
    required this.parentName,
    required this.children,
  });

  Iterable<TunProcessTreeNode> get descendants sync* {
    for (final child in children) {
      yield child;
      yield* child.descendants;
    }
  }

  int get descendantInstanceCount =>
      descendants.fold(0, (count, node) => count + node.process.pids.length);
}

/// Return every application group that can be expanded in the picker.
///
/// Process trees are expanded initially so leaf applications such as a game
/// executable are not hidden several launcher levels deep.
Set<String> expandableTunProcessNames(Iterable<TunProcessTreeNode> roots) {
  final names = <String>{};

  void visit(TunProcessTreeNode node) {
    if (node.children.isNotEmpty) names.add(node.process.name);
    for (final child in node.children) {
      visit(child);
    }
  }

  for (final root in roots) {
    visit(root);
  }
  return names;
}

/// Match process identity, friendly name, path, PID, and common initialisms.
bool tunProcessMatchesQuery(TunProcessInfo process, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return true;
  if (process.name.contains(normalized) ||
      process.displayName.toLowerCase().contains(normalized) ||
      process.aliases.any(
        (alias) => alias.toLowerCase().contains(normalized),
      ) ||
      process.executablePaths.any(
        (path) => path.toLowerCase().contains(normalized),
      ) ||
      process.pids.any((pid) => pid.toString().contains(normalized))) {
    return true;
  }

  final words = RegExp(
    r'[a-z0-9]+',
  ).allMatches(process.displayName.toLowerCase());
  final initialism = words.map((match) => match.group(0)![0]).join();
  return initialism.length > 1 && initialism.contains(normalized);
}

/// Reconstruct application trees from native PID/parent-PID snapshots.
///
/// Windows system and shell processes form implementation roots for most GUI
/// applications, so those edges are intentionally cut. Non-system launcher
/// chains, such as RiotClientServices -> LeagueClient -> game processes, remain
/// visible and match the native ancestor-based bypass behavior.
List<TunProcessTreeNode> buildTunProcessForest(List<TunProcessInfo> processes) {
  final byName = <String, TunProcessInfo>{
    for (final process in processes) process.name: process,
  };
  final byPid = <int, TunProcessInfo>{};
  for (final process in processes) {
    for (final instance in process.instances) {
      byPid[instance.pid] = process;
    }
  }

  final parentVotes = <String, Map<String, int>>{};
  for (final child in processes) {
    for (final instance in child.instances) {
      final parentPid = instance.parentPid;
      final parent = parentPid == null ? null : byPid[parentPid];
      if (parent == null ||
          parent.name == child.name ||
          !_shouldAttachToApplication(parent, child)) {
        continue;
      }
      parentVotes
          .putIfAbsent(child.name, () => <String, int>{})
          .update(parent.name, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  final parentByName = <String, String>{};
  final childrenWithParents = parentVotes.keys.toList()..sort();
  for (final child in childrenWithParents) {
    final candidates = parentVotes[child]!.entries.toList()
      ..sort((left, right) {
        final countOrder = right.value.compareTo(left.value);
        return countOrder != 0 ? countOrder : left.key.compareTo(right.key);
      });
    for (final candidate in candidates) {
      if (!_wouldCreateCycle(child, candidate.key, parentByName)) {
        parentByName[child] = candidate.key;
        break;
      }
    }
  }

  final childrenByName = <String, List<String>>{};
  for (final entry in parentByName.entries) {
    childrenByName.putIfAbsent(entry.value, () => []).add(entry.key);
  }
  for (final children in childrenByName.values) {
    children.sort();
  }

  TunProcessTreeNode buildNode(String name) {
    final children = (childrenByName[name] ?? const <String>[])
        .where(byName.containsKey)
        .map(buildNode)
        .toList(growable: false);
    return TunProcessTreeNode(
      process: byName[name]!,
      parentName: parentByName[name],
      children: children,
    );
  }

  final roots = byName.keys
      .where((name) => !parentByName.containsKey(name))
      .map(buildNode)
      .toList();
  roots.sort((left, right) {
    final childOrder = right.descendantInstanceCount.compareTo(
      left.descendantInstanceCount,
    );
    return childOrder != 0
        ? childOrder
        : left.process.name.compareTo(right.process.name);
  });
  return roots;
}

bool _wouldCreateCycle(
  String child,
  String parent,
  Map<String, String> parentByName,
) {
  var current = parent;
  final visited = <String>{};
  while (visited.add(current)) {
    if (current == child) return true;
    final next = parentByName[current];
    if (next == null) return false;
    current = next;
  }
  return true;
}

bool _shouldAttachToApplication(TunProcessInfo parent, TunProcessInfo child) {
  if (_systemBoundaryNames.contains(parent.name)) return false;
  final parentPath = parent.executablePaths.firstOrNull;
  final childPath = child.executablePaths.firstOrNull;
  if (parentPath != null && _isWindowsSystemPath(parentPath)) return false;
  if (childPath != null && _isWindowsSystemPath(childPath)) return false;
  return true;
}

bool _isWindowsSystemPath(String path) {
  final normalized = path.replaceAll('/', r'\').toLowerCase();
  return normalized.contains(r'\windows\system32\') ||
      normalized.contains(r'\windows\syswow64\') ||
      normalized.endsWith(r'\windows\explorer.exe');
}

const _systemBoundaryNames = <String>{
  'cmd',
  'conhost',
  'csrss',
  'explorer',
  'openconsole',
  'powershell',
  'proxy_ui',
  'pwsh',
  'services',
  'sihost',
  'smss',
  'svchost',
  'system',
  'taskhostw',
  'wininit',
  'winlogon',
  'windowsterminal',
};
