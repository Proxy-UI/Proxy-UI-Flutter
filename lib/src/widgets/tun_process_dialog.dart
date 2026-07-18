import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ffi/proxy_service.dart';
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
    // loading state is rendered even on systems with many processes.
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
    setState(() {
      _processes = sorted;
      _selfProcess = selfProcess;
      _loading = false;
    });
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

  @override
  Widget build(BuildContext context) {
    final query = _normalize(_searchController.text);
    final visible = _processes.where((process) {
      if (query.isEmpty) return true;
      return process.name.contains(query) ||
          process.executablePaths.any(
            (path) => path.toLowerCase().contains(query),
          ) ||
          process.pids.any((pid) => pid.toString().contains(query));
    }).toList();
    visible.sort((left, right) {
      final leftSelected =
          (_selected.contains(left.name) || left.name == _selfProcess) ? 0 : 1;
      final rightSelected =
          (_selected.contains(right.name) || right.name == _selfProcess)
          ? 0
          : 1;
      final selectedOrder = leftSelected.compareTo(rightSelected);
      return selectedOrder != 0
          ? selectedOrder
          : left.name.compareTo(right.name);
    });

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.security_outlined),
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
        width: 560,
        height: 520,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Search processes',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_selected.length + (_selfProcess == null ? 0 : 1)} selected',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualController,
                    onSubmitted: (_) => _addManualProcess(),
                    decoration: const InputDecoration(
                      labelText: 'Executable name',
                      prefixIcon: Icon(Icons.add_box_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: _addManualProcess,
                  tooltip: 'Add process',
                  icon: const Icon(Icons.add),
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
                      itemBuilder: (context, index) {
                        final process = visible[index];
                        final name = process.name;
                        final isSelf = name == _selfProcess;
                        final instanceLabel = process.pids.isEmpty
                            ? 'Not currently running'
                            : process.pids.length == 1
                            ? 'PID ${process.pids.single}'
                            : '${process.pids.length} processes | PIDs ${process.pids.take(3).join(', ')}${process.pids.length > 3 ? ', ...' : ''}';
                        final path = process.executablePaths.isEmpty
                            ? null
                            : process.executablePaths.first;
                        return CheckboxListTile(
                          dense: true,
                          secondary: Icon(
                            isSelf
                                ? Icons.verified_user_outlined
                                : Icons.window_outlined,
                          ),
                          title: Text('$name.exe'),
                          subtitle: Text(
                            [
                              if (isSelf) 'Current process | always bypassed',
                              if (!isSelf) instanceLabel,
                              if (path != null) path,
                            ].join('\n'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          value: isSelf || _selected.contains(name),
                          onChanged: isSelf
                              ? null
                              : (selected) {
                                  setState(() {
                                    if (selected ?? false) {
                                      _selected.add(name);
                                    } else {
                                      _selected.remove(name);
                                    }
                                  });
                                },
                        );
                      },
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
}

String _normalize(String name) {
  final lower = name.trim().toLowerCase();
  return lower.endsWith('.exe') ? lower.substring(0, lower.length - 4) : lower;
}
