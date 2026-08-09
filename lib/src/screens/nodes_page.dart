import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/node_filter.dart';
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
  final Map<String, bool> _switchLoading = {};
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _keyController = TextEditingController();
  final _searchController = TextEditingController();
  bool _showConfig = true;
  bool _controlFieldsInitialized = false;
  bool _isTestingAll = false;
  String? _selectedGroupId;
  String _searchQuery = '';
  String? _selectedCountry;

  void _initializeControlFields(ProxyState state) {
    _hostController.text = state.nodesServerHost.isEmpty
        ? state.config.serverHost
        : state.nodesServerHost;
    _portController.text = state.nodesServerPort.toString();
    _keyController.text = state.nodesSessionKey ?? '';
    _controlFieldsInitialized = true;
  }

  void _persistControlFields() {
    context.read<ProxyState>().updateNodesServerConfig(
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text),
      sessionKey: _keyController.text.trim(),
    );
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _keyController.dispose();
    _searchController.dispose();
    super.dispose();
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
          ToastUtils.showError(state.lastError ?? 'Failed to switch node');
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

  Future<void> _testAllNodes(ProxyState state) async {
    if (_isTestingAll) return;
    final nodes = _filterNodes(state);
    if (nodes.isEmpty) return;

    setState(() => _isTestingAll = true);
    var nextIndex = 0;
    var failures = 0;

    Future<void> worker() async {
      while (nextIndex < nodes.length) {
        final node = nodes[nextIndex++];
        final verification = await state.verifyNode(node);
        if (verification == null || !verification.isVerified) failures++;
      }
    }

    final workerCount = nodes.length < 8 ? nodes.length : 8;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    if (!mounted) return;
    setState(() => _isTestingAll = false);
    if (failures == 0) {
      ToastUtils.showSuccess('Tested ${nodes.length} nodes');
    } else {
      ToastUtils.showError(
        'Tested ${nodes.length}: ${nodes.length - failures} reachable, '
        '$failures failed',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ProxyState>(
      builder: (context, state, _) {
        if (state.isInitialized && !_controlFieldsInitialized) {
          _initializeControlFields(state);
        }
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
                              onChanged: (_) => _persistControlFields(),
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
                              onChanged: (_) => _persistControlFields(),
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
                        onChanged: (_) => _persistControlFields(),
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
        _buildNodeToolbar(state),
        const SizedBox(height: 12),
        if (state.groups.isNotEmpty) _buildGroupSelector(state),
        if (state.groups.isNotEmpty) const SizedBox(height: 12),
        if (filteredNodes.isEmpty)
          _buildEmptyFilterState(state)
        else
          ...filteredNodes.map((node) => _buildNodeCard(context, state, node)),
      ],
    );
  }

  List<NodeInfo> _filterNodes(ProxyState state) {
    return filterNodeCatalog(
      nodes: state.nodes,
      groups: state.groups,
      selectedGroupId: _selectedGroupId,
      selectedCountry: _selectedCountry,
      query: _searchQuery,
      sortByLatency: state.sortNodesByLatency,
      countryOf: state.effectiveCountry,
    );
  }

  /// One chip per country in the catalogue, so picking a region is a click
  /// rather than a search term the user has to know.
  Widget _buildCountryChips(ProxyState state) {
    final facets = countryFacets(
      nodes: state.nodes,
      countryOf: state.effectiveCountry,
    );
    if (facets.length < 2) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilterChip(
            label: Text('All (${state.nodes.length})'),
            selected: _selectedCountry == null,
            onSelected: (_) => setState(() => _selectedCountry = null),
          ),
          for (final facet in facets)
            FilterChip(
              avatar: _buildCountryFlag(facet.code),
              label: Text('${facet.code} (${facet.count})'),
              selected: _selectedCountry == facet.code,
              onSelected: (selected) => setState(
                () => _selectedCountry = selected ? facet.code : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNodeToolbar(ProxyState state) {
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: _isTestingAll ? null : () => _testAllNodes(state),
          icon: _isTestingAll
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_ping, size: 18),
          label: const Text('Test all'),
        ),
        PopupMenuButton<bool>(
          tooltip: 'Sort nodes',
          initialValue: state.sortNodesByLatency,
          onSelected: state.setSortNodesByLatency,
          itemBuilder: (context) => [
            CheckedPopupMenuItem(
              value: false,
              checked: !state.sortNodesByLatency,
              child: const Text('Server order'),
            ),
            CheckedPopupMenuItem(
              value: true,
              checked: state.sortNodesByLatency,
              child: const Text('Latency'),
            ),
          ],
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outline),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort, size: 18),
                const SizedBox(width: 8),
                Text(state.sortNodesByLatency ? 'Latency' : 'Server order'),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSearchField(),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight, child: actions),
              _buildCountryChips(state),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _buildSearchField()),
                const SizedBox(width: 8),
                actions,
              ],
            ),
            _buildCountryChips(state),
          ],
        );
      },
    );
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _searchController,
      onChanged: (value) => setState(() => _searchQuery = value),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search nodes, regions, addresses, or groups',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searchQuery.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
              ),
        border: const OutlineInputBorder(),
      ),
    );
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

  Widget _buildEmptyFilterState(ProxyState state) {
    if (_searchQuery.trim().isNotEmpty) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.search_off),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No nodes match "${_searchQuery.trim()}"',
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
    final verificationNote = _buildVerificationNote(context, state, node);

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
                _buildNodeFlag(context, state, node),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${state.effectiveCountry(node)}'
                    '${node.region.isNotEmpty ? ' - ${node.region}' : ''}',
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

            if (verificationNote != null) ...[
              const SizedBox(height: 4),
              verificationNote,
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
                ElevatedButton.icon(
                  onPressed: state.isVerifyingNode(node)
                      ? null
                      : () => _verifyNode(context, node),
                  icon: state.isVerifyingNode(node)
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed, size: 18),
                  label: const Text('Test'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
                if (!isCurrent)
                  ElevatedButton.icon(
                    onPressed:
                        _switchLoading[node.nodeId] == true || state.isTunBusy
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

  /// The flag slot, which doubles as the verification indicator.
  ///
  /// A node that did not answer gets a distinct mark rather than the flag of a
  /// country its traffic never reaches — the whole point of verifying is that
  /// the catalogue's claim cannot be trusted on its own.
  Widget _buildNodeFlag(BuildContext context, ProxyState state, NodeInfo node) {
    final theme = Theme.of(context);
    if (state.isVerifyingNode(node)) {
      return const SizedBox(
        width: 28,
        height: 20,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final verification = state.verificationFor(node);
    if (verification != null && !verification.isVerified) {
      return Tooltip(
        message: verification.error ?? 'This node did not answer',
        child: SizedBox(
          width: 28,
          height: 20,
          child: Icon(
            Icons.cloud_off,
            size: 18,
            color: theme.colorScheme.error,
          ),
        ),
      );
    }

    return _buildCountryFlag(state.effectiveCountry(node));
  }

  /// Extract country code from string and build flag widget
  Widget _buildCountryFlag(String country) {
    // Try to find a 2-letter country code in the string
    final match = RegExp(r'[A-Z]{2}').firstMatch(country.toUpperCase());
    if (match != null) {
      // country_flags 4.x moved sizing into the theme object.
      return CountryFlag.fromCountryCode(
        match.group(0)!,
        theme: const ImageTheme(height: 20, width: 28),
      );
    }
    // Fallback to a generic icon
    return const Icon(Icons.flag, size: 20);
  }

  /// One line describing what the last probe found, or nothing before one ran.
  Widget? _buildVerificationNote(
    BuildContext context,
    ProxyState state,
    NodeInfo node,
  ) {
    final verification = state.verificationFor(node);
    if (verification == null) return null;
    final theme = Theme.of(context);

    if (!verification.isVerified) {
      return Text(
        'Unreachable · ${verification.error ?? 'no answer'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    final drifted = verification.disagreesWith(node.country);
    final parts = <String>[
      'Egress ${verification.countryCode}',
      if (verification.egressIp.isNotEmpty) verification.egressIp,
      if (verification.latencyMs != null) '${verification.latencyMs}ms',
    ];
    return Text(
      drifted
          ? '${parts.join(' · ')} — catalogue says ${node.country}'
          : parts.join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: drifted
            ? theme.colorScheme.tertiary
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Future<void> _verifyNode(BuildContext context, NodeInfo node) async {
    final state = context.read<ProxyState>();
    final verification = await state.verifyNode(node);
    if (verification == null) return;
    if (verification.isVerified) {
      ToastUtils.showSuccess(
        'Traffic leaves from ${verification.countryCode}'
        '${verification.egressIp.isEmpty ? '' : ' (${verification.egressIp})'}',
      );
    } else {
      ToastUtils.showError(
        verification.error ?? 'Could not reach ${node.addr}',
      );
    }
  }
}
