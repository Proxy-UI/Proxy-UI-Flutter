import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ffi/proxy_service.dart';
import '../models/tun_process_tree.dart';
import '../providers/proxy_provider.dart';
import '../utils/toast_utils.dart';

/// Windows process picker for the runtime-updatable TUN bypass policy.
class TunProcessDialog extends StatefulWidget {
  const TunProcessDialog({super.key});

  @override
  State<TunProcessDialog> createState() => _TunProcessDialogState();
}

class _TunProcessDialogState extends State<TunProcessDialog> {
  final _searchController = TextEditingController();
  final _manualController = TextEditingController();
  final Set<String> _selected = {};
  final Set<String> _expanded = {};
  List<TunProcessInfo> _processes = const [];
  String? _selfProcess;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selected.addAll(
      context.read<ProxyState>().config.tunBypassProcesses.map(_normalize),
    );
    _loadProcesses();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _loadProcesses() async {
    setState(() => _loading = true);
    // Defer native enumeration until after the dialog's first frame so its
    // loading state is rendered even on systems with many process icons.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final options = context.read<ProxyState>().getTunProcessOptions();
    if (!mounted) return;

    final processes = <String, TunProcessInfo>{
      for (final process in options.processes)
        _normalize(process.name): process,
    };
    final selfProcess = options.selfProcess == null
        ? null
        : _normalize(options.selfProcess!);
    if (selfProcess != null && selfProcess.isNotEmpty) {
      processes.putIfAbsent(
        selfProcess,
        () => TunProcessInfo(
          name: selfProcess,
          pids: const [],
          executablePaths: const [],
        ),
      );
    }
    for (final name in _selected) {
      processes.putIfAbsent(
        name,
        () => TunProcessInfo(
          name: name,
          pids: const [],
          executablePaths: const [],
        ),
      );
    }
    final sorted = processes.values.toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    final forest = buildTunProcessForest(sorted);
    setState(() {
      _processes = sorted;
      _selfProcess = selfProcess;
      _removeInheritedSelections(forest);
      _expandSelectedPaths(forest);
      _loading = false;
    });
  }

  void _removeInheritedSelections(List<TunProcessTreeNode> forest) {
    void visit(TunProcessTreeNode node, bool ancestorSelected) {
      if (ancestorSelected) {
        _selected.remove(node.process.name);
      }
      final selectedHere =
          ancestorSelected || _selected.contains(node.process.name);
      for (final child in node.children) {
        visit(child, selectedHere);
      }
    }

    for (final root in forest) {
      visit(root, false);
    }
  }

  void _expandSelectedPaths(List<TunProcessTreeNode> forest) {
    bool visit(TunProcessTreeNode node) {
      final containsSelection =
          _selected.contains(node.process.name) || node.children.any(visit);
      if (containsSelection && node.children.isNotEmpty) {
        _expanded.add(node.process.name);
      }
      return containsSelection;
    }

    for (final root in forest) {
      visit(root);
    }
  }

  void _addManualProcess() {
    final name = _normalize(_manualController.text);
    if (name.isEmpty) return;
    setState(() {
      _selected.add(name);
      if (!_processes.any((process) => process.name == name)) {
        _processes = [
          ..._processes,
          TunProcessInfo(name: name, pids: const [], executablePaths: const []),
        ]..sort((left, right) => left.name.compareTo(right.name));
      }
      _manualController.clear();
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final userProcesses =
        _selected.where((name) => name != _selfProcess).toList()..sort();
    final success = await context.read<ProxyState>().updateTunBypassProcesses(
      userProcesses,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (success) {
      Navigator.of(context).pop();
      ToastUtils.showSuccess(
        'Bypass applied; affected connections are reconnecting',
      );
    } else {
      ToastUtils.showError(
        context.read<ProxyState>().lastError ?? 'Failed to update TUN bypass',
      );
    }
  }

  void _setSelected(TunProcessTreeNode node, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(node.process.name);
        // Parent matching already includes every descendant. Removing redundant
        // explicit names keeps the persisted policy stable across PID changes.
        for (final descendant in node.descendants) {
          _selected.remove(descendant.process.name);
        }
        if (node.children.isNotEmpty) {
          _expanded.add(node.process.name);
        }
      } else {
        _selected.remove(node.process.name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final forest = buildTunProcessForest(_processes);
    final query = _normalize(_searchController.text);
    final visible = _flattenVisibleProcesses(forest, query);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.account_tree_outlined),
          const SizedBox(width: 12),
          const Expanded(child: Text('Bypass Applications')),
          IconButton(
            onPressed: _loading ? null : _loadProcesses,
            tooltip: 'Refresh processes',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      content: SizedBox(
        width: 680,
        height: 580,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Search applications, paths, or PIDs',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_selected.length + (_selfProcess == null ? 0 : 1)} selected',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _manualController,
                    onSubmitted: (_) => _addManualProcess(),
                    decoration: InputDecoration(
                      labelText: 'Executable name',
                      prefixIcon: const Icon(Icons.add_box_outlined),
                      suffixIcon: IconButton(
                        onPressed: _addManualProcess,
                        tooltip: 'Add process',
                        icon: const Icon(Icons.add),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) =>
                          _buildProcessRow(visible[index]),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: const Text('Apply'),
        ),
      ],
    );
  }

  List<_VisibleProcess> _flattenVisibleProcesses(
    List<TunProcessTreeNode> forest,
    String query,
  ) {
    final rows = <_VisibleProcess>[];

    bool matches(TunProcessTreeNode node) {
      final process = node.process;
      return process.name.contains(query) ||
          process.executablePaths.any(
            (path) => path.toLowerCase().contains(query),
          ) ||
          process.pids.any((pid) => pid.toString().contains(query));
    }

    bool subtreeMatches(TunProcessTreeNode node) {
      return query.isEmpty ||
          matches(node) ||
          node.children.any(subtreeMatches);
    }

    void visit(TunProcessTreeNode node, int depth, String? inheritedBy) {
      if (!subtreeMatches(node)) return;
      rows.add(
        _VisibleProcess(node: node, depth: depth, inheritedBy: inheritedBy),
      );
      final showChildren =
          query.isNotEmpty || _expanded.contains(node.process.name);
      if (!showChildren) return;
      final nextInherited =
          inheritedBy ??
          ((_selected.contains(node.process.name) ||
                  node.process.name == _selfProcess)
              ? node.process.name
              : null);
      for (final child in node.children) {
        visit(child, depth + 1, nextInherited);
      }
    }

    final roots = forest.toList()
      ..sort((left, right) {
        final leftSelected = _selected.contains(left.process.name) ? 0 : 1;
        final rightSelected = _selected.contains(right.process.name) ? 0 : 1;
        final selectedOrder = leftSelected.compareTo(rightSelected);
        return selectedOrder != 0
            ? selectedOrder
            : left.process.name.compareTo(right.process.name);
      });
    for (final root in roots) {
      visit(root, 0, null);
    }
    return rows;
  }

  Widget _buildProcessRow(_VisibleProcess row) {
    final node = row.node;
    final process = node.process;
    final name = process.name;
    final isSelf = name == _selfProcess;
    final inherited = row.inheritedBy != null;
    final selected = isSelf || inherited || _selected.contains(name);
    final path = process.executablePaths.firstOrNull;
    final childApplications = node.descendants.length;
    final details = <String>[
      if (isSelf) 'Current process | always bypassed',
      if (inherited) 'Included by ${row.inheritedBy}.exe',
      if (!isSelf && !inherited)
        process.pids.isEmpty
            ? 'Not currently running'
            : process.pids.length == 1
            ? 'PID ${process.pids.single}'
            : '${process.pids.length} instances',
      if (childApplications > 0)
        '$childApplications child applications | ${node.descendantInstanceCount} processes',
      if (path != null) path,
    ];

    return Material(
      color: selected
          ? Theme.of(
              context,
            ).colorScheme.secondaryContainer.withValues(alpha: .38)
          : Colors.transparent,
      child: InkWell(
        onTap: isSelf || inherited ? null : () => _setSelected(node, !selected),
        child: Padding(
          padding: EdgeInsets.only(left: row.depth * 24.0, right: 8),
          child: SizedBox(
            height: 72,
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: node.children.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () => setState(() {
                            if (!_expanded.add(name)) {
                              _expanded.remove(name);
                            }
                          }),
                          tooltip: _expanded.contains(name)
                              ? 'Collapse process tree'
                              : 'Expand process tree',
                          icon: Icon(
                            _expanded.contains(name)
                                ? Icons.expand_more
                                : Icons.chevron_right,
                          ),
                        ),
                ),
                Checkbox(
                  value: selected,
                  onChanged: isSelf || inherited
                      ? null
                      : (value) => _setSelected(node, value ?? false),
                ),
                const SizedBox(width: 6),
                _ProcessIcon(process: process),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$name.exe',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                          if (inherited)
                            Tooltip(
                              message:
                                  'Bypassed through ${row.inheritedBy}.exe',
                              child: const Icon(
                                Icons.account_tree_outlined,
                                size: 18,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        details.join(' | '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VisibleProcess {
  final TunProcessTreeNode node;
  final int depth;
  final String? inheritedBy;

  const _VisibleProcess({
    required this.node,
    required this.depth,
    required this.inheritedBy,
  });
}

class _ProcessIcon extends StatelessWidget {
  final TunProcessInfo process;

  const _ProcessIcon({required this.process});

  @override
  Widget build(BuildContext context) {
    final icon = process.iconPng;
    if (icon == null) {
      return Icon(
        Icons.apps_outlined,
        size: 28,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
    }
    return Image.memory(
      icon,
      width: 28,
      height: 28,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => Icon(
        Icons.apps_outlined,
        size: 28,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

String _normalize(String name) {
  final lower = name.trim().toLowerCase();
  return lower.endsWith('.exe') ? lower.substring(0, lower.length - 4) : lower;
}
