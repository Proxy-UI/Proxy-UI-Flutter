import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/node_model.dart';
import '../providers/proxy_provider.dart';
import '../utils/toast_utils.dart';

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
  final _searchController = TextEditingController();
  bool _showConfig = true;
  String? _selectedGroupId;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<ProxyState>();
      _hostController.text = state.nodesServerHost.isEmpty
          ? state.config.serverHost
          : state.nodesServerHost;
      _portController.text = state.nodesServerPort.toString();
      _keyController.text = state.nodesSessionKey ?? '';
    });
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _keyController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _saveControlServer() {
    final state = context.read<ProxyState>();
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text);
    if (host.isEmpty) {
      ToastUtils.showError('Host is required');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      ToastUtils.showError('Invalid port number (1-65535)');
      return;
    }
    state.updateNodesServerConfig(
      host: host,
      port: port,
      sessionKey: _keyController.text.trim(),
    );
    ToastUtils.showSuccess('Control server saved');
  }

  Future<void> _fetchNodes() async {
    final state = context.read<ProxyState>();
    final port = int.tryParse(_portController.text);
    if (port == null || port < 1 || port > 65535) {
      ToastUtils.showError('Invalid port number (1-65535)');
      return;
    }

    state.updateNodesServerConfig(
      host: _hostController.text.trim(),
      port: port,
      sessionKey: _keyController.text.trim(),
    );
    await state.fetchNodes();
  }

  Future<void> _onRefresh() async {
    await _fetchNodes();
  }

  Future<void> _exportConfig(BuildContext context, NodeInfo node) async {
    final state = context.read<ProxyState>();
    try {
      await state.exportNodeConfig(node);
      if (mounted) {
        ToastUtils.showSuccess('Config exported to clipboard');
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError('Failed to export: $e');
      }
    }
  }

  Future<void> _switchNode(BuildContext context, NodeInfo node) async {
    final state = context.read<ProxyState>();
    setState(() => _switchLoading[node.nodeId] = true);

    try {
      final success = await state.switchToNode(node);
      if (mounted) {
        if (success) {
          ToastUtils.showSuccess('Switched to ${node.displayName}');
        } else {
          ToastUtils.showError('Failed to start proxy');
        }
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError('Failed to switch: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _switchLoading[node.nodeId] = false);
      }
    }
  }

  Future<void> _pingNode(BuildContext context, NodeInfo node) async {
    final state = context.read<ProxyState>();
    setState(() {
      _pingLoading[node.nodeId] = true;
    });

    try {
      await state.pingNode(node);
      // No toast on success - latency is already displayed on the card
    } catch (e) {
      if (mounted) {
        ToastUtils.showError('Ping failed: $e');
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
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: state.isLoadingNodes
                                  ? null
                                  : _saveControlServer,
                              icon: const Icon(Icons.save),
                              label: const Text('Save'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: state.isLoadingNodes
                                  ? null
                                  : () => _fetchNodes(),
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
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Search bar (only when nodes are loaded)
            if (state.nodes.isNotEmpty) _buildSearchBar(),
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

    if (_selectedGroupId != null &&
        !state.groups.any((g) => g.groupId == _selectedGroupId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _selectedGroupId = null);
        }
      });
    }

    final filteredNodes = _filterNodes(state);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (state.groups.isNotEmpty) _buildGroupSelector(state),
        if (state.groups.isNotEmpty) const SizedBox(height: 12),
        if (filteredNodes.isEmpty)
          _buildEmptyResults(state)
        else
          ...filteredNodes.map((node) => _buildNodeCard(context, state, node)),
      ],
    );
  }

  List<NodeInfo> _filterNodes(ProxyState state) {
    Iterable<NodeInfo> nodes = state.nodes;

    // Group filter (chip selection)
    if (_selectedGroupId != null && state.groups.isNotEmpty) {
      final group = state.groups.firstWhere(
        (g) => g.groupId == _selectedGroupId,
        orElse: () => state.groups.first,
      );
      final nodeIdSet = group.nodeIds.toSet();
      nodes = nodes.where((node) => nodeIdSet.contains(node.nodeId));
    }

    // Text search across country / region / IP / group name
    final query = _searchQuery.trim().toLowerCase();
    if (query.isNotEmpty) {
      nodes = nodes.where((node) => _matchesQuery(node, query, state));
    }

    return nodes.toList();
  }

  bool _matchesQuery(NodeInfo node, String query, ProxyState state) {
    if (node.country.toLowerCase().contains(query) ||
        node.region.toLowerCase().contains(query) ||
        node.addr.toLowerCase().contains(query) ||
        node.nodeId.toLowerCase().contains(query)) {
      return true;
    }
    // Match against the names of groups this node belongs to
    for (final group in state.groups) {
      if (group.name.toLowerCase().contains(query) &&
          group.nodeIds.contains(node.nodeId)) {
        return true;
      }
    }
    return false;
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: _searchController,
        onChanged: (value) => setState(() => _searchQuery = value),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search by country, region, IP or group',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear',
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildEmptyResults(ProxyState state) {
    final query = _searchQuery.trim();
    if (query.isNotEmpty) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.search_off),
              const SizedBox(width: 8),
              Expanded(child: Text('No nodes match "$query"')),
            ],
          ),
        ),
      );
    }
    return _buildEmptyGroupState(state);
  }

  Widget _buildGroupSelector(ProxyState state) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.group, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Groups',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                if (state.groupsError != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '(${state.groupsError})',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: _selectedGroupId == null,
                  onSelected: (_) => setState(() => _selectedGroupId = null),
                ),
                ...state.groups.map(
                  (group) => ChoiceChip(
                    label: Text('${group.name} (${group.nodeIds.length})'),
                    selected: _selectedGroupId == group.groupId,
                    onSelected: (_) =>
                        setState(() => _selectedGroupId = group.groupId),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyGroupState(ProxyState state) {
    if (_selectedGroupId == null) {
      return const SizedBox.shrink();
    }
    if (state.groups.isEmpty) {
      return const SizedBox.shrink();
    }
    final group = state.groups.firstWhere(
      (g) => g.groupId == _selectedGroupId,
      orElse: () => state.groups.first,
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.info_outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No nodes in group "${group.name}"',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeCard(BuildContext context, ProxyState state, NodeInfo node) {
    final isCurrent = state.isCurrentNode(node);

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
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
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
                  color: _latencyColor(node.latencyMs!),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],

            const SizedBox(height: 12),

            // Action buttons
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Export Config button (always available)
                ElevatedButton.icon(
                  onPressed: () => _exportConfig(context, node),
                  icon: const Icon(Icons.file_download, size: 18),
                  label: const Text('Export'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),

                // Ping button (always available — no switching required)
                ElevatedButton.icon(
                  onPressed: _pingLoading[node.nodeId] == true
                      ? null
                      : () => _pingNode(context, node),
                  icon: _pingLoading[node.nodeId] == true
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed, size: 18),
                  label: const Text('Ping'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),

                // Switch button (only for non-current nodes)
                if (!isCurrent)
                  ElevatedButton.icon(
                    onPressed: _switchLoading[node.nodeId] == true
                        ? null
                        : () => _switchNode(context, node),
                    icon: _switchLoading[node.nodeId] == true
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
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
  }

  Color _latencyColor(int ms) {
    if (ms < 100) return Colors.green;
    if (ms < 300) return Colors.orange;
    return Colors.red;
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
