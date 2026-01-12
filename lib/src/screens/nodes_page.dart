import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/proxy_provider.dart';

/// Nodes page for managing proxy nodes.
class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  final Map<String, bool> _pingLoading = {};
  final Map<String, bool> _switchLoading = {};
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _keyController = TextEditingController();
  bool _showConfig = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<ProxyState>();
      _hostController.text = state.nodesServerHost;
      _portController.text = state.nodesServerPort.toString();
      _keyController.text = state.nodesSessionKey ?? '';
    });
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  void _fetchNodes() {
    final state = context.read<ProxyState>();
    state.updateNodesServerConfig(
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text) ?? 1081,
      sessionKey: _keyController.text.trim(),
    );
    state.fetchNodes();
  }

  Future<void> _onRefresh() async {
    _fetchNodes();
  }

  Future<void> _exportConfig(BuildContext context, int index) async {
    final state = context.read<ProxyState>();
    final node = state.nodes[index];
    final messenger = ScaffoldMessenger.of(context);

    try {
      await state.exportNodeConfig(node);
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            width: 300,
            content: Text('Config exported to clipboard'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            width: 400,
            content: Text('Failed to export: $e'),
          ),
        );
      }
    }
  }

  Future<void> _switchNode(BuildContext context, int index) async {
    final state = context.read<ProxyState>();
    final node = state.nodes[index];
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _switchLoading[node.nodeId] = true);

    try {
      final success = await state.switchToNode(node);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            width: 300,
            content: Text(
              success
                  ? 'Switched to ${node.displayName}'
                  : 'Failed to start proxy',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            width: 400,
            content: Text('Failed to switch: $e'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _switchLoading[node.nodeId] = false);
      }
    }
  }

  Future<void> _pingNode(BuildContext context, int index) async {
    final state = context.read<ProxyState>();
    final node = state.nodes[index];
    final messenger = ScaffoldMessenger.of(context);

    setState(() {
      _pingLoading[node.nodeId] = true;
    });

    try {
      await state.pingCurrentNode();
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            width: 300,
            content: Text('Latency: ${node.latencyMs}ms'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            width: 400,
            content: Text('Ping failed: $e'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _pingLoading[node.nodeId] = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ProxyState>(
      builder: (context, state, _) {
        return Column(
          children: [
            // Server config card
            Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.dns, size: 20),
                        const SizedBox(width: 8),
                        const Text(
                          'Control Server',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: Icon(
                            _showConfig ? Icons.expand_less : Icons.expand_more,
                          ),
                          onPressed: () =>
                              setState(() => _showConfig = !_showConfig),
                        ),
                      ],
                    ),
                    if (_showConfig) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _hostController,
                              decoration: const InputDecoration(
                                labelText: 'Host',
                                hintText: 'e.g. 192.168.1.100',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 1,
                            child: TextField(
                              controller: _portController,
                              decoration: const InputDecoration(
                                labelText: 'Port',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.number,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _keyController,
                        decoration: const InputDecoration(
                          labelText: 'Session Key (optional)',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: state.isLoadingNodes ? null : _fetchNodes,
                          icon: state.isLoadingNodes
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh),
                          label: const Text('Fetch Nodes'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Nodes list
            Expanded(
              child: RefreshIndicator(
                onRefresh: _onRefresh,
                child: _buildBody(context, state),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, ProxyState state) {
    if (state.isLoadingNodes) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.nodesError != null) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text('Error: ${state.nodesError}'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _onRefresh,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (state.nodes.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.dns_outlined, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                const Text('No nodes available'),
                const SizedBox(height: 8),
                const Text(
                  'Pull down to refresh',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: state.nodes.length,
      itemBuilder: (context, index) {
        final node = state.nodes[index];
        final isCurrent = state.isCurrentNode(node);
        final canPing = isCurrent && state.isRunning;

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header with badge
                Row(
                  children: [
                    if (isCurrent)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'CURRENT NODE',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    if (isCurrent) const SizedBox(width: 8),
                    _buildCountryFlag(node.country),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${node.country}${node.region.isNotEmpty ? ' - ${node.region}' : ''}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Address
                Text(
                  node.addr,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),

                // Last seen
                Text(
                  'Last seen: ${_formatLastSeen(node.lastSeen)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),

                // Latency (if available)
                if (node.latencyMs != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Latency: ${node.latencyMs}ms',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],

                const SizedBox(height: 12),

                // Action buttons
                Row(
                  children: [
                    // Export Config button (always available)
                    ElevatedButton.icon(
                      onPressed: () => _exportConfig(context, index),
                      icon: const Icon(Icons.file_download, size: 18),
                      label: const Text('Export'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Switch or Ping button
                    if (isCurrent && canPing)
                      ElevatedButton.icon(
                        onPressed: _pingLoading[node.nodeId] == true
                            ? null
                            : () => _pingNode(context, index),
                        icon: _pingLoading[node.nodeId] == true
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.speed, size: 18),
                        label: const Text('Ping'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                      )
                    else if (!isCurrent)
                      ElevatedButton.icon(
                        onPressed: _switchLoading[node.nodeId] == true
                            ? null
                            : () => _switchNode(context, index),
                        icon: _switchLoading[node.nodeId] == true
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.swap_horiz, size: 18),
                        label: const Text('Switch'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatLastSeen(DateTime lastSeen) {
    final now = DateTime.now();
    final diff = now.difference(lastSeen);

    if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }

  /// Extract country code from string and build flag widget
  Widget _buildCountryFlag(String country) {
    // Try to find a 2-letter country code in the string
    final match = RegExp(r'[A-Z]{2}').firstMatch(country.toUpperCase());
    if (match != null) {
      return CountryFlag.fromCountryCode(
        match.group(0)!,
        height: 20,
        width: 28,
      );
    }
    // Fallback to a generic icon
    return const Icon(Icons.flag, size: 20);
  }
}
