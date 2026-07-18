import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
  List<String> _processes = const [];
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

    final names = <String>{...options.processes.map(_normalize), ..._selected};
    final selfProcess = options.selfProcess == null
        ? null
        : _normalize(options.selfProcess!);
    if (selfProcess != null && selfProcess.isNotEmpty) {
      names.add(selfProcess);
    }
    final sorted = names.where((name) => name.isNotEmpty).toList()..sort();
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
      if (!_processes.contains(name)) {
        _processes = [..._processes, name]..sort();
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
      ToastUtils.showSuccess('TUN bypass updated');
    } else {
      ToastUtils.showError(
        context.read<ProxyState>().lastError ?? 'Failed to update TUN bypass',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _normalize(_searchController.text);
    final visible = _processes
        .where((name) => query.isEmpty || name.contains(query))
        .toList(growable: false);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.security_outlined),
          const SizedBox(width: 12),
          const Expanded(child: Text('TUN Process Bypass')),
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
                        final name = visible[index];
                        final isSelf = name == _selfProcess;
                        return CheckboxListTile(
                          dense: true,
                          secondary: Icon(
                            isSelf
                                ? Icons.verified_user_outlined
                                : Icons.apps_outlined,
                          ),
                          title: Text(name),
                          subtitle: isSelf
                              ? const Text('Current process (required)')
                              : null,
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
